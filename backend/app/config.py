"""Settings, read once from environment variables (see backend/README.md)."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = BACKEND_DIR.parent


def default_catalog_dir() -> Path:
    """content/catalog in a checkout, /srv/content/catalog inside the Docker image."""
    for candidate in (REPO_DIR / "content" / "catalog", Path("/srv/content/catalog")):
        if candidate.is_dir():
            return candidate
    return REPO_DIR / "content" / "catalog"


def _int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a whole number, got {raw!r}") from exc


def _float(env: Mapping[str, str], name: str, default: float) -> float:
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number, got {raw!r}") from exc


def _bool(env: Mapping[str, str], name: str, default: bool = False) -> bool:
    raw = env.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    # The homr command line, split with shlex. Tests point it at a fake script.
    homr_cmd: str = "homr"
    # Extra arguments placed before the image path. Empty for homr 0.7.0: its command
    # line takes only the image (plus --init/--debug/--cache/--output-*); any flag it
    # does not know makes it exit 2 before reading the picture, so add nothing here
    # that is not in `homr --help` for the pinned version.
    homr_extra_args: str = ""
    # The app gives up on a scan after 120 s without a reply (APIClient.swift,
    # timeoutInterval), so homr gets at most this long and the wait in the queue is
    # capped too (OMR_QUEUE_WAIT_SECONDS; a scan that cannot start in time is a 503).
    omr_timeout_seconds: float = 110.0
    omr_queue_wait_seconds: float = 30.0
    daily_scan_limit: int = 30
    omr_queue_limit: int = 4
    max_upload_bytes: int = 15 * 1024 * 1024
    max_image_side: int = 3000
    catalog_dir: Path = field(default_factory=default_catalog_dir)
    include_drafts: bool = False
    # Where per-request scratch directories are created (None = system temp dir).
    work_dir: Path | None = None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        catalog = env.get("CATALOG_DIR", "").strip()
        work = env.get("OMR_WORK_DIR", "").strip()
        return cls(
            homr_cmd=env.get("HOMR_CMD", "").strip() or "homr",
            homr_extra_args=env.get("HOMR_EXTRA_ARGS", ""),
            omr_timeout_seconds=_float(env, "OMR_TIMEOUT_SECONDS", 110.0),
            omr_queue_wait_seconds=_float(env, "OMR_QUEUE_WAIT_SECONDS", 30.0),
            daily_scan_limit=_int(env, "DAILY_SCAN_LIMIT", 30),
            omr_queue_limit=_int(env, "OMR_QUEUE_LIMIT", 4),
            max_upload_bytes=_int(env, "MAX_UPLOAD_BYTES", 15 * 1024 * 1024),
            max_image_side=_int(env, "MAX_IMAGE_SIDE", 3000),
            catalog_dir=Path(catalog) if catalog else default_catalog_dir(),
            include_drafts=_bool(env, "INCLUDE_DRAFTS"),
            work_dir=Path(work) if work else None,
        )
