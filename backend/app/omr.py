"""Adapter around the homr command-line tool.

homr is AGPL. We never import it: it runs as a separate process, unmodified, exactly
as a person would run it from a terminal (`homr <image>`), and only its output file
is read back. Checked against the homr 0.7.0 wheel on PyPI (homr/main.py), which is
the version pinned in requirements.txt:

* `homr <image.png>` writes `<image>.musicxml` next to the input image, plus a
  `<image>_teaser.png` preview and a `<image>_tesseract_input.png` crop for its own
  title OCR — so each job gets its own fresh directory, which is also its cwd.
* The 0.7.0 command line knows only the image path and --init/--debug/--cache/
  --output-large-page/--output-metronome/--output-tempo/--write-staff-positions/
  --read-staff-positions/--coreml-encoder. There is no `--no-title` (that is on the
  main branch only); an unknown flag makes homr exit 2 before it reads the picture.
  Title detection (RapidOCR, models bundled in the rapidocr wheel) therefore runs on
  every scan; its result only lands in `<work-title>`.
* A recognition error raises inside homr: non-zero exit, and homr deletes any
  half-written output file. We treat "non-zero exit", "no output file" and "empty
  output file" all as failures.
* `homr --init` downloads the models into site-packages and exits (Dockerfile).

Every file we create for a request — the normalised image, homr's output, anything
else homr leaves behind — lives in one temporary directory that is removed in a
`finally` block before the response goes out. homr is started in its own process
group so a timeout (or the client going away) kills everything it spawned. Nothing
from the request is logged: on failure only the tail of homr's stderr is kept, with
its "Found title:" line (OCR of the text above the first staff) removed, and the
engine gets a minimal environment rather than a copy of the server's.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shlex
import shutil
import signal
import tempfile
from collections.abc import Mapping
from pathlib import Path

from .config import Settings
from .imaging import normalise_image

log = logging.getLogger("auditioner.omr")

INPUT_NAME = "page.png"
OUTPUT_NAME = "page.musicxml"
STDERR_TAIL_CHARS = 400
KILL_GRACE_SECONDS = 10

# Environment variables handed to homr. Everything else (and in particular any secret
# the server may hold later: Anthropic, YouTube, Supabase keys) stays with us.
ENV_KEEP = frozenset({
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TZ",
    "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE",
    "TMPDIR", "TEMP", "TMP",
    "VIRTUAL_ENV", "CONDA_PREFIX",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    "TF_CPP_MIN_LOG_LEVEL",
})
ENV_KEEP_PREFIXES = (
    "PYTHON", "LD_", "DYLD_",
    "OMP_", "ORT_", "ONNX", "KMP_", "OPENBLAS_", "MKL_", "NUMEXPR_", "OPENCV_",
    "HOMR_", "FAKE_HOMR_",  # homr's own knobs, and the test double's
)


class EngineError(Exception):
    """homr failed (crashed, produced nothing, or could not be started)."""


class EngineTimeout(EngineError):
    """homr ran longer than allowed and was killed."""


def build_command(settings: Settings, image_path: Path) -> list[str]:
    """The argv to run. homr runs with the scratch directory as its cwd, so any relative
    path in HOMR_CMD (e.g. `python3 tests/fixtures/fake_homr.py`) is made absolute
    against the directory the server was started from."""
    command = [_absolute_if_file(tok) for tok in shlex.split(settings.homr_cmd)]
    return [*command, *shlex.split(settings.homr_extra_args), str(image_path)]


def _absolute_if_file(token: str) -> str:
    path = Path(token)
    if not path.is_absolute() and (os.sep in token or token.endswith(".py")) and path.is_file():
        return str(path.resolve())
    return token


def subprocess_env(source: Mapping[str, str] | None = None) -> dict[str, str]:
    """The environment homr runs with: a whitelist of `source` (default os.environ)."""
    source = os.environ if source is None else source
    env = {
        key: value
        for key, value in source.items()
        if key in ENV_KEEP or key.startswith(ENV_KEEP_PREFIXES)
    }
    env.setdefault("PYTHONUNBUFFERED", "1")
    return env


def scrub_stderr(stderr: bytes, limit: int = STDERR_TAIL_CHARS) -> str:
    """The last `limit` characters of homr's stderr, minus the line that carries the
    OCR'd title of the scanned page (the only request content homr prints)."""
    text = stderr.decode("utf-8", "replace")
    kept = [line for line in text.splitlines() if not line.startswith("Found title")]
    return "\n".join(kept)[-limit:].strip()


async def recognise(image_bytes: bytes, settings: Settings, timeout: float | None = None) -> bytes:
    """Run homr on the uploaded picture and return the raw MusicXML bytes.

    `timeout` caps the run below settings.omr_timeout_seconds (the endpoint passes
    what is left of the app's patience after the wait in the queue).
    Raises NotAnImage / ImageTooLarge (from imaging), EngineTimeout or EngineError.
    """
    limit = settings.omr_timeout_seconds
    if timeout is not None:
        limit = min(limit, timeout)
    if settings.work_dir is not None:
        settings.work_dir.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="omr-", dir=settings.work_dir))
    try:
        image_path = workdir / INPUT_NAME
        await asyncio.to_thread(normalise_image, image_bytes, image_path, settings.max_image_side)
        stderr_tail = await _run(settings, workdir, image_path, limit)
        output = workdir / OUTPUT_NAME
        if not output.is_file():
            log.error("homr produced no output file; stderr tail: %s", stderr_tail)
            raise EngineError("no output file")
        data = output.read_bytes()
        if not data.strip():
            log.error("homr produced an empty output file; stderr tail: %s", stderr_tail)
            raise EngineError("empty output file")
        return data
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


async def _run(settings: Settings, workdir: Path, image_path: Path, timeout: float) -> str:
    command = build_command(settings, image_path)
    try:
        proc = await asyncio.create_subprocess_exec(
            *command,
            cwd=str(workdir),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            env=subprocess_env(),
            start_new_session=True,  # own process group: see _kill
        )
    except (OSError, ValueError) as exc:
        log.error("could not start the OMR engine (%s): %s", command[0], exc)
        raise EngineError(f"could not start {command[0]}") from exc

    try:
        _, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        await _kill(proc)
        log.warning("homr timed out after %.0f s", timeout)
        raise EngineTimeout("timed out") from None
    except BaseException:
        # Cancelled (the client went away) or anything unexpected: never leave a
        # homr process behind, it would keep the CPU busy for minutes.
        await _kill(proc)
        raise

    tail = scrub_stderr(stderr)
    if proc.returncode != 0:
        log.error("homr exited with status %s; stderr tail: %s", proc.returncode, tail)
        raise EngineError(f"exit status {proc.returncode}")
    return tail


async def _kill(proc: asyncio.subprocess.Process) -> None:
    """SIGKILL homr and every process in its group, then reap it."""
    if proc.returncode is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except ProcessLookupError:
                pass
    try:
        await asyncio.wait_for(proc.wait(), timeout=KILL_GRACE_SECONDS)
    except asyncio.TimeoutError:  # pragma: no cover - the process ignored SIGKILL
        log.error("homr (pid %s) did not die after SIGKILL", proc.pid)
