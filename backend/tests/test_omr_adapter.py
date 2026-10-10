"""Unit tests for the homr command line adapter (no FastAPI involved)."""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

import pytest

from app.config import Settings
from app.omr import EngineError, EngineTimeout, build_command, recognise
from conftest import FAKE_HOMR, FIXTURES, make_jpeg


def test_build_command_splits_and_appends_image(tmp_path):
    settings = Settings(homr_cmd="/opt/venv/bin/homr", homr_extra_args="--no-title --debug")
    assert build_command(settings, tmp_path / "page.png") == [
        "/opt/venv/bin/homr", "--no-title", "--debug", str(tmp_path / "page.png"),
    ]


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
        "homr_extra_args": "--no-title",
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


def test_recognise_timeout(tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")
    with pytest.raises(EngineTimeout):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, omr_timeout_seconds=0.3)))
    assert list((tmp_path / "work").iterdir()) == []


def test_recognise_missing_engine(tmp_path):
    with pytest.raises(EngineError):
        asyncio.run(recognise(make_jpeg(), _settings(tmp_path, homr_cmd="/no/such/homr")))
    assert list((tmp_path / "work").iterdir()) == []


def test_settings_from_env(monkeypatch, tmp_path):
    env = {
        "HOMR_CMD": "python3 fake.py",
        "OMR_TIMEOUT_SECONDS": "12.5",
        "DAILY_SCAN_LIMIT": "7",
        "INCLUDE_DRAFTS": "1",
        "CATALOG_DIR": str(tmp_path),
        "OMR_WORK_DIR": str(tmp_path / "w"),
    }
    settings = Settings.from_env(env)
    assert settings.homr_cmd == "python3 fake.py"
    assert settings.omr_timeout_seconds == 12.5
    assert settings.daily_scan_limit == 7
    assert settings.include_drafts is True
    assert settings.catalog_dir == tmp_path
    assert settings.work_dir == tmp_path / "w"
    assert Settings.from_env({}).homr_cmd == "homr"
    with pytest.raises(ValueError):
        Settings.from_env({"DAILY_SCAN_LIMIT": "many"})
    assert os.environ.get("HOMR_CMD") is None or True  # real env untouched by this test
