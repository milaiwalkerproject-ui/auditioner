"""POST /v1/omr through the fake homr script."""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.limits import ConcurrencyGuard
from app.main import create_app
from conftest import DEVICE, FIXTURES, make_jpeg, make_png, post_omr


def _xml(body: dict) -> ET.Element:
    assert body["musicxml"].startswith('<?xml version="1.0" encoding="UTF-8"?>')
    return ET.fromstring(body["musicxml"])


def test_happy_path(client):
    response = post_omr(client, make_jpeg(), hints=["VIOLONCELLO", "Allegro"])
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"musicxml", "warnings", "engine", "measures"}
    assert body["engine"] == "homr"
    assert body["measures"] == 4
    assert body["warnings"] == ["Bar 3 doesn't add up (3.5 beats in a 4/4 bar) — check it"]
    root = _xml(body)
    assert root.find("part-list/score-part/part-name").text == "Cello"
    assert root.find("part/measure/attributes/transpose") is None
    # homr's image-position comments survive the round trip
    assert "<!-- imgpos: 120, 200 -->" in body["musicxml"]


def test_png_upload_accepted(client, png_bytes):
    response = post_omr(client, png_bytes, filename="page.png", content_type="image/png")
    assert response.status_code == 200, response.text


def test_double_bass_transposition(client):
    response = post_omr(client, instrument="double-bass", transposition=-12)
    assert response.status_code == 200, response.text
    root = _xml(response.json())
    transpose = root.find("part/measure/attributes/transpose")
    assert transpose is not None
    assert transpose.findtext("chromatic") == "0"
    assert transpose.findtext("octave-change") == "-1"
    assert root.find("part-list/score-part/part-name").text == "Double bass"


def test_clarinet_transposition(client):
    response = post_omr(client, instrument="clarinet", transposition=-2)
    root = _xml(response.json())
    transpose = root.find("part/measure/attributes/transpose")
    assert transpose.findtext("chromatic") == "-2"
    assert transpose.find("octave-change") is None


def test_meter_override(client):
    response = post_omr(client, meter="3/4")
    assert response.status_code == 200
    body = response.json()
    assert body["warnings"][0] == "Meter set to 3/4 from the catalogue"
    root = _xml(body)
    for time in root.iter("time"):
        assert time.findtext("beats") == "3"
        assert time.findtext("beat-type") == "4"
    # bars 2 and 4 hold four beats, bar 3 three and a half: all re-checked against 3/4
    assert "Bar 2 doesn't add up (4 beats in a 3/4 bar) — check it" in body["warnings"]
    assert "Bar 3 doesn't add up (3.5 beats in a 3/4 bar) — check it" in body["warnings"]
    assert "Bar 4 doesn't add up (4 beats in a 3/4 bar) — check it" in body["warnings"]


def test_tempo_hint_added(client):
    response = post_omr(client, hints=["Andante con moto", "♩ = 92"])
    root = _xml(response.json())
    sound = root.find("part/measure[1]/direction/sound")
    assert sound is not None
    assert sound.get("tempo") == "92"
    assert root.find("part/measure[1]/direction/direction-type/metronome/per-minute").text == "92"


def test_no_tempo_without_hint(client):
    response = post_omr(client, hints=["Andante con moto"])
    root = _xml(response.json())
    assert root.find("part/measure/direction/sound") is None


# ----------------------------------------------------------------- bad input


def test_missing_device_id(client):
    response = post_omr(client, headers={"X-App-Version": "0.1"})
    assert response.status_code == 400
    assert "X-Device-Id" in response.json()["detail"]


def test_blank_device_id(client):
    response = post_omr(client, headers={"X-Device-Id": "   "})
    assert response.status_code == 400


def test_unknown_instrument(client):
    response = post_omr(client, instrument="kazoo")
    assert response.status_code == 400
    assert "kazoo" in response.json()["detail"]


def test_bad_transposition(client):
    assert post_omr(client, transposition=99).status_code == 400
    response = post_omr(client, transposition="lots")
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)
    assert "transposition" in response.json()["detail"]


def test_bad_meter(client):
    response = post_omr(client, meter="waltz")
    assert response.status_code == 400
    assert response.json()["detail"] == "The meter should look like 3/4 or 6/8."


def test_bad_hints(client):
    assert post_omr(client, hints="not json").status_code == 400
    assert post_omr(client, hints='{"a": 1}').status_code == 400
    assert post_omr(client, hints="[1, 2]").status_code == 400
    assert post_omr(client, hints="").status_code == 200


def test_missing_image_field(client):
    response = client.post("/v1/omr", data={"instrument": "cello"}, headers=DEVICE)
    assert response.status_code == 422
    assert "image" in response.json()["detail"]


def test_not_an_image(client):
    response = post_omr(client, b"%PDF-1.4 not a picture", filename="part.pdf", content_type="application/pdf")
    assert response.status_code == 415
    assert "JPEG or PNG" in response.json()["detail"]


def test_empty_file(client):
    response = post_omr(client, b"")
    assert response.status_code == 415


def test_too_large_by_content_length(client):
    big = b"\xff" * (15 * 1024 * 1024 + 1)
    response = post_omr(client, big)
    assert response.status_code == 413
    assert "15 MB" in response.json()["detail"]


def test_too_large_by_file_size(settings_factory):
    # A tiny limit so the chunked reader (not the Content-Length check) refuses the file.
    app = create_app(settings_factory(max_upload_bytes=1000))
    client = TestClient(app)
    response = post_omr(client, make_jpeg(800, 800))
    assert response.status_code == 413


# ------------------------------------------------------------ limits & engine


def test_daily_limit(settings_factory):
    app = create_app(settings_factory(daily_scan_limit=2))
    client = TestClient(app)
    assert post_omr(client).status_code == 200
    assert post_omr(client).status_code == 200
    third = post_omr(client)
    assert third.status_code == 429
    assert third.json()["detail"] == "Daily scan limit reached. Try again tomorrow."
    # another device is unaffected
    other = post_omr(client, headers={"X-Device-Id": "another-device"})
    assert other.status_code == 200


def test_limit_not_charged_for_bad_input(settings_factory):
    app = create_app(settings_factory(daily_scan_limit=1))
    client = TestClient(app)
    assert post_omr(client, instrument="kazoo").status_code == 400
    assert post_omr(client, b"garbage").status_code == 415
    assert post_omr(client).status_code == 200


def test_busy(settings_factory):
    app = create_app(settings_factory())
    app.state.guard = ConcurrencyGuard(max_running=0, max_waiting=0)  # nothing may run
    client = TestClient(app)
    response = post_omr(client)
    assert response.status_code == 503
    assert response.json()["detail"] == "Busy — try again in a minute"
    assert response.headers.get("retry-after") == "60"
    # the scan was not charged against the daily limit
    assert app.state.limiter.remaining(DEVICE["X-Device-Id"]) == app.state.settings.daily_scan_limit


def test_engine_timeout(settings_factory, monkeypatch):
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")
    app = create_app(settings_factory(omr_timeout_seconds=0.5))
    client = TestClient(app)
    response = post_omr(client)
    assert response.status_code == 504
    assert "took too long" in response.json()["detail"]


@pytest.mark.parametrize("mode", ["crash", "silent", "garbage", "empty"])
def test_engine_failure(client, monkeypatch, mode):
    monkeypatch.setenv("FAKE_HOMR_MODE", mode)
    response = post_omr(client)
    assert response.status_code == 500
    assert response.json()["detail"] == "The notes couldn't be read from this page. Try a clearer, straighter photo."


def test_engine_not_installed(settings_factory):
    app = create_app(settings_factory(homr_cmd="/nonexistent/homr-binary"))
    client = TestClient(app)
    assert post_omr(client).status_code == 500


# --------------------------------------------------------------- temp files


def _record(tmp_path: Path, monkeypatch) -> Path:
    record = tmp_path / "record.json"
    monkeypatch.setenv("FAKE_HOMR_RECORD", str(record))
    return record


def test_temp_dir_deleted_after_success(client, settings, tmp_path, monkeypatch):
    record = _record(tmp_path, monkeypatch)
    assert post_omr(client).status_code == 200
    seen = json.loads(record.read_text())
    work_dir = Path(seen["dir"])
    assert work_dir.parent == settings.work_dir
    assert seen["files"] == ["page.png"]  # only the normalised image, nothing else
    assert seen["cwd"] == seen["dir"]
    assert seen["argv"][0] == "--no-title"
    assert not work_dir.exists()
    assert list(settings.work_dir.iterdir()) == []


@pytest.mark.parametrize("mode", ["crash", "silent", "garbage"])
def test_temp_dir_deleted_after_failure(client, settings, tmp_path, monkeypatch, mode):
    record = _record(tmp_path, monkeypatch)
    monkeypatch.setenv("FAKE_HOMR_MODE", mode)
    assert post_omr(client).status_code == 500
    work_dir = Path(json.loads(record.read_text())["dir"])
    assert not work_dir.exists()


def test_temp_dir_deleted_after_timeout(settings_factory, tmp_path, monkeypatch):
    record = _record(tmp_path, monkeypatch)
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")
    settings = settings_factory(omr_timeout_seconds=0.5)
    client = TestClient(create_app(settings))
    assert post_omr(client).status_code == 504
    work_dir = Path(json.loads(record.read_text())["dir"])
    assert not work_dir.exists()
    assert list(settings.work_dir.iterdir()) == []


def test_upload_is_normalised_before_homr(client, settings, tmp_path, monkeypatch):
    """The engine only ever sees our re-encoded PNG, never the original upload."""
    monkeypatch.setenv("FAKE_HOMR_RECORD", str(tmp_path / "record.json"))
    monkeypatch.setenv("FAKE_HOMR_MODE", "hang")

    # Capture the normalised image by swapping the fake's mode: run the fake with a
    # wrapper that copies the input before homr "processes" it.
    wrapper = tmp_path / "copying_homr.py"
    wrapper.write_text(
        "import shutil, sys\n"
        "from pathlib import Path\n"
        "image = Path(sys.argv[-1])\n"
        f"shutil.copyfile(image, {str(tmp_path / 'seen.png')!r})\n"
        f"shutil.copyfile({str(FIXTURES / 'homr_sample.musicxml')!r}, image.with_suffix('.musicxml'))\n"
    )
    monkeypatch.delenv("FAKE_HOMR_MODE")
    app = create_app(
        type(settings)(**{**settings.__dict__, "homr_cmd": f"{sys.executable} {wrapper}"})
    )
    client = TestClient(app)
    response = post_omr(client, make_png(4000, 1000), filename="page.png", content_type="image/png")
    assert response.status_code == 200, response.text
    from PIL import Image

    with Image.open(tmp_path / "seen.png") as im:
        assert im.format == "PNG"
        assert im.mode == "RGB"
        assert max(im.size) == 3000
        assert im.size == (3000, 750)
