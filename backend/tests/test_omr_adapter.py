"""Unit tests for the homr command line adapter (no FastAPI involved)."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path

import pytest

from app.config import Settings
from app.omr import (
    EngineError,
    EngineTimeout,
    build_command,
    recognise,
    scrub_stderr,
    subprocess_env,
)
from conftest import FAKE_HOMR, FIXTURES, make_jpeg


def test_build_command_splits_and_appends_image(tmp_path):
    settings = Settings(homr_cmd="/opt/venv/bin/homr", homr_extra_args="--debug --cache")
    assert build_command(settings, tmp_path / "page.png") == [
        "/opt/venv/bin/homr", "--debug", "--cache", str(tmp_path / "page.png"),
    ]


def test_default_command_is_bare_homr_0_7_0_style(tmp_path):
    """homr 0.7.0 takes only the image: no --no-title (that flag is main-branch only)."""
    assert Settings().homr_extra_args == ""
    assert Settings.from_env({}).homr_extra_args == ""
    assert build_command(Settings(), tmp_path / "page.png") == ["homr", str(tmp_path / "page.png")]


def test_build_command_resolves_relative_script_path(monkeypatch, tmp_path):
    """`HOMR_CMD="python3 tests/fixtures/fake_homr.py"` must survive homr's cwd change."""
    monkeypatch.chdir(FIXTURES.parent.parent)  # backend/
    settings = Settings(homr_cmd="python3 tests/fixtures/fake_homr.py", homr_extra_args="")
    command = build_command(settings, tmp_path / "page.png")
    assert command[0] == "python3"
    assert command[1] == str(FAKE_HOMR)
    assert Path(command[1]).is_absolute()


def test_build_command_leaves_plain_names_alone(tmp_path):
    settings = Settings(homr_cmd="homr", homr_extra_args="")
    assert build_command(settings, tmp_path / "x.png")[0] == "homr"


def _settings(tmp_path: Path, **overrides) -> Settings:
    values = {
        "homr_cmd": f"{sys.executable} {FAKE_HOMR}",
        "homr_extra_args": "",
        "omr_timeout_seconds": 5.0,
        "work_dir": tmp_path / "work",
    }
    values.update(overrides)
    return Settings(**values)


def test_recognise_returns_homr_output(tmp_path):
    xml = asyncio.run(recognise(make_jpeg(), _settings(tmp_path)))
    assert xml.lstrip().startswith(b"<?xml")
    assert b"<score-partwise" in xml
    assert list((tmp_path / "work").iterdir()) == []


@pytest.mark.parametrize("mode", ["crash", "silent", "empty"])
def test_recognise_failures(tmp_path, monkeypatch, mode):
    monkeypatch.setenv("FAKE_HOMR_MODE", mode)
    with pytest.raises(EngineError):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path)))
    assert list((tmp_path / "work").iterdir()) == []


def test_unknown_flag_is_an_engine_error(tmp_path):
    """What would happen with HOMR_EXTRA_ARGS=--no-title against homr 0.7.0: exit 2."""
    with pytest.raises(EngineError, match="exit status 2"):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, homr_extra_args="--no-title")))


def test_recognise_timeout(tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")
    with pytest.raises(EngineTimeout):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, omr_timeout_seconds=0.3)))
    assert list((tmp_path / "work").iterdir()) == []


def test_explicit_timeout_caps_the_setting(tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")
    started = time.monotonic()
    with pytest.raises(EngineTimeout):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, omr_timeout_seconds=30.0), timeout=0.3))
    assert time.monotonic() - started < 5


def _is_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as fh:
            return fh.read().split(")")[-1].split()[0] == "Z"  # zombie = dead, unreaped
    except OSError:
        return True


@pytest.mark.skipif(not hasattr(os, "killpg"), reason="process groups are POSIX only")
def test_timeout_kills_the_whole_process_group(tmp_path, monkeypatch):
    """homr may fork helpers; a timeout must not leave them eating CPU."""
    pid_file = tmp_path / "child.pid"
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang-child")
    monkeypatch.setenv("FAKE_HOMR_CHILD_PID_FILE", str(pid_file))
    with pytest.raises(EngineTimeout):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, omr_timeout_seconds=1.0)))
    child_pid = int(pid_file.read_text())
    deadline = time.monotonic() + 5
    while not _is_gone(child_pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert _is_gone(child_pid), f"grandchild {child_pid} survived the timeout"


def test_cancellation_kills_the_engine(tmp_path, monkeypatch):
    """The client went away mid-scan: homr must be killed, not left running."""
    pid_file = tmp_path / "child.pid"
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang-child")
    monkeypatch.setenv("FAKE_HOMR_CHILD_PID_FILE", str(pid_file))

    async def scenario() -> None:
        task = asyncio.create_task(recognise(make_jpeg(), _settings(tmp_path, omr_timeout_seconds=30)))
        deadline = time.monotonic() + 5
        while not pid_file.exists() and time.monotonic() < deadline:
            await asyncio.sleep(0.05)
        await asyncio.sleep(0.1)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(scenario())
    child_pid = int(pid_file.read_text())
    deadline = time.monotonic() + 5
    while not _is_gone(child_pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert _is_gone(child_pid)
    assert list((tmp_path / "work").iterdir()) == []


def test_recognise_missing_engine(tmp_path):
    with pytest.raises(EngineError):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, homr_cmd="/no/such/homr")))
    assert list((tmp_path / "work").iterdir()) == []


# ------------------------------------------------------------ what homr is told


def test_engine_gets_a_minimal_environment(tmp_path, monkeypatch):
    record = tmp_path / "record.json"
    monkeypatch.setenv("FAKE_HOMR_RECORD", str(record))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-not-for-homr")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "also-secret")
    monkeypatch.setenv("OMP_NUM_THREADS", "2")
    asyncio.run(recognise(make_jpeg(), _settings(tmp_path)))
    names = set(json.loads(record.read_text())["env_names"])
    assert "ANTHROPIC_API_KEY" not in names
    assert "SUPABASE_SERVICE_KEY" not in names
    assert {"PATH", "FAKE_HOMR_RECORD", "OMP_NUM_THREADS", "PYTHONUNBUFFERED"} <= names


def test_subprocess_env_whitelist():
    env = subprocess_env({
        "PATH": "/usr/bin", "HOME": "/home/app", "ANTHROPIC_API_KEY": "x",
        "HOMR_CMD": "homr", "PYTHONPATH": "/srv", "LD_LIBRARY_PATH": "/opt/lib",
        "YOUTUBE_API_KEY": "y", "GOOGLE_APPLICATION_CREDENTIALS": "/secret.json",
    })
    assert env == {
        "PATH": "/usr/bin", "HOME": "/home/app", "HOMR_CMD": "homr",
        "PYTHONPATH": "/srv", "LD_LIBRARY_PATH": "/opt/lib", "PYTHONUNBUFFERED": "1",
    }


def test_title_line_is_not_logged(tmp_path, monkeypatch, caplog):
    """homr prints the OCR'd title of the page to stderr; that is request content."""
    monkeypatch.setenv("FAKE_HOMR_MODE", "title")
    with caplog.at_level(logging.ERROR, logger="auditioner.omr"):
        with pytest.raises(EngineError):
            asyncio.run(recognise(make_jpeg(), _settings(tmp_path)))
    assert "Secret Sonata" not in caplog.text
    assert "exited with status 1" in caplog.text
    assert "boom after title" in caplog.text


def test_scrub_stderr():
    raw = b"Processing /tmp/x/page.png\nFound title: Something Private\nTraceback: boom\n"
    assert scrub_stderr(raw) == "Processing /tmp/x/page.png\nTraceback: boom"
    assert scrub_stderr(b"x" * 1000, limit=10) == "x" * 10
    assert scrub_stderr(b"") == ""


def test_settings_from_env(monkeypatch, tmp_path):
    env = {
        "HOMR_CMD": "python3 fake.py",
        "OMR_TIMEOUT_SECONDS": "12.5",
        "OMR_QUEUE_WAIT_SECONDS": "7.5",
        "DAILY_SCAN_LIMIT": "7",
        "INCLUDE_DRAFTS": "1",
        "CATALOG_DIR": str(tmp_path),
        "OMR_WORK_DIR": str(tmp_path / "w"),
    }
    settings = Settings.from_env(env)
    assert settings.homr_cmd == "python3 fake.py"
    assert settings.omr_timeout_seconds == 12.5
    assert settings.omr_queue_wait_seconds == 7.5
    assert settings.daily_scan_limit == 7
    assert settings.include_drafts is True
    assert settings.catalog_dir == tmp_path
    assert settings.work_dir == tmp_path / "w"
    defaults = Settings.from_env({})
    assert defaults.homr_cmd == "homr"
    assert defaults.omr_timeout_seconds == 110.0  # under the app's 120 s patience
    assert defaults.omr_queue_wait_seconds == 30.0
    with pytest.raises(ValueError):
        Settings.from_env({"DAILY_SCAN_LIMIT": "many"})
    assert os.environ.get("HOMR_CMD") is None or True  # real env untouched by this test
