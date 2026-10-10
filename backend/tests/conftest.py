"""Shared fixtures: an app wired to the fake homr script and a small catalogue."""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from typing import Any, Callable

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FAKE_HOMR = FIXTURES / "fake_homr.py"
SAMPLE_XML = FIXTURES / "homr_sample.musicxml"
FIXTURE_CATALOG = FIXTURES / "catalog"
REPO_CATALOG = Path(__file__).resolve().parents[2] / "content" / "catalog"


def make_png(width: int = 600, height: int = 400, mode: str = "RGB") -> bytes:
    image = Image.new(mode, (width, height), "white" if mode != "RGBA" else (255, 255, 255, 0))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def make_jpeg(width: int = 600, height: int = 400) -> bytes:
    image = Image.new("RGB", (width, height), "white")
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=80)
    return buffer.getvalue()


@pytest.fixture
def png_bytes() -> bytes:
    return make_png()


@pytest.fixture
def settings_factory(tmp_path: Path) -> Callable[..., Settings]:
    def factory(**overrides: Any) -> Settings:
        values: dict[str, Any] = {
            "homr_cmd": f"{sys.executable} {FAKE_HOMR}",
            "homr_extra_args": "",
            "omr_timeout_seconds": 10.0,
            "daily_scan_limit": 30,
            "omr_queue_limit": 4,
            "catalog_dir": FIXTURE_CATALOG,
            "work_dir": tmp_path / "omr-work",
        }
        values.update(overrides)
        return Settings(**values)

    return factory


@pytest.fixture
def settings(settings_factory: Callable[..., Settings]) -> Settings:
    return settings_factory()


@pytest.fixture
def app(settings: Settings) -> FastAPI:
    return create_app(settings)


@pytest.fixture
def client(app: FastAPI) -> TestClient:
    return TestClient(app)


DEVICE = {"X-Device-Id": "test-device-0001", "X-App-Version": "0.1"}


def post_omr(
    client: TestClient,
    image: bytes | None = None,
    *,
    instrument: str = "cello",
    transposition: int | str = 0,
    meter: str | None = None,
    hints: list[str] | str | None = None,
    headers: dict[str, str] | None = None,
    filename: str = "page.jpg",
    content_type: str = "image/jpeg",
):
    data: dict[str, str] = {"instrument": instrument, "transposition": str(transposition)}
    if meter is not None:
        data["meter"] = meter
    if hints is not None:
        data["hints"] = hints if isinstance(hints, str) else json.dumps(hints)
    files = {"image": (filename, image if image is not None else make_jpeg(), content_type)}
    return client.post("/v1/omr", data=data, files=files, headers=DEVICE if headers is None else headers)
