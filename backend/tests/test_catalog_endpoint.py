from __future__ import annotations

import json
import time

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from conftest import FIXTURE_CATALOG, REPO_CATALOG


def test_catalog_file_with_etag(client):
    response = client.get("/v1/catalog/cello")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")
    etag = response.headers["etag"]
    assert etag.startswith('"') and etag.endswith('"')
    assert response.content == (FIXTURE_CATALOG / "cello.json").read_bytes()
    assert response.json()["instrument"] == "cello"

    again = client.get("/v1/catalog/cello", headers={"If-None-Match": etag})
    assert again.status_code == 304
    assert again.content == b""
    assert again.headers["etag"] == etag

    stale = client.get("/v1/catalog/cello", headers={"If-None-Match": '"something-else"'})
    assert stale.status_code == 200


def test_catalog_404s(client):
    assert client.get("/v1/catalog/kazoo").status_code == 404
    response = client.get("/v1/catalog/tuba")  # a real instrument with no file yet
    assert response.status_code == 404
    assert response.json()["detail"] == "No catalogue for 'tuba' yet."


def test_catalog_reloads_when_file_changes(settings_factory, tmp_path):
    catalog_dir = tmp_path / "catalog"
    catalog_dir.mkdir()
    path = catalog_dir / "viola.json"
    path.write_text(json.dumps({"instrument": "viola", "excerpts": []}))
    client = TestClient(create_app(settings_factory(catalog_dir=catalog_dir)))
    first = client.get("/v1/catalog/viola")
    assert first.status_code == 200
    time.sleep(0.01)
    path.write_text(json.dumps({"instrument": "viola", "excerpts": [], "version": "2"}))
    second = client.get("/v1/catalog/viola")
    assert second.headers["etag"] != first.headers["etag"]
    assert second.json()["version"] == "2"


@pytest.mark.skipif(not list(REPO_CATALOG.glob("*.json")), reason="no real catalogue files in the repo yet")
def test_real_catalogue_served(settings_factory):
    client = TestClient(create_app(settings_factory(catalog_dir=REPO_CATALOG)))
    for path in sorted(REPO_CATALOG.glob("*.json")):
        response = client.get(f"/v1/catalog/{path.stem}")
        assert response.status_code == 200
        assert response.content == path.read_bytes()
