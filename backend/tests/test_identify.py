from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from app.catalog import Catalog, fold, haystack, rank, tokens
from app.main import create_app
from conftest import FIXTURE_CATALOG, REPO_CATALOG


def test_fold_and_tokens():
    assert fold("Dvořák") == "dvorak"
    assert tokens("L. van BEETHOVEN, Op. 67 — Symphonie Nr. 5") == ["van", "beethoven", "op", "67", "symphonie", "nr"]
    assert tokens("") == []


def test_haystack_fields():
    excerpt = {
        "composer": "Antonín Dvořák",
        "work": "Symphony No. 9",
        "title": "Movement II",
        "catalogueNumber": "Op. 95",
        "movement": {"title": "Largo"},
        "part": "Cello",
    }
    assert haystack(excerpt) == {"antonin", "dvorak", "symphony", "no", "movement", "ii", "op", "95", "largo", "cello"}


def test_rank_prefers_the_right_movement():
    catalog = Catalog(FIXTURE_CATALOG)
    pool = catalog.excerpts("cello")
    ranked = rank("VIOLONCELLO  Symphony No. 5  L. van Beethoven Op. 67  Andante con moto", pool)
    assert ranked[0][0] == "beethoven-symphony-5-ii"
    assert ranked[1][0] == "beethoven-symphony-5-iii"
    assert 0 < ranked[1][1] < ranked[0][1] <= 1.0
    assert all(0 < s <= 1 for _, s in ranked)


def test_rank_diacritics_and_prefix():
    catalog = Catalog(FIXTURE_CATALOG)
    pool = catalog.excerpts("cello")
    ranked = rank("Dvorak Symphonie Largo", pool)  # "symphonie" prefix-matches "symphony"? no: hay must start with the query token
    assert ranked[0][0] == "dvorak-symphony-9-ii"
    ranked = rank("DVOŘÁK sympho", pool)  # 5+ character OCR fragment matches by prefix
    assert ranked[0][0] == "dvorak-symphony-9-ii"
    assert "symphony" in haystack(pool[0])


def test_rank_empty_and_no_match():
    catalog = Catalog(FIXTURE_CATALOG)
    pool = catalog.excerpts("cello")
    assert rank("", pool) == []
    assert rank("zzzz qqqq", pool) == []


def test_rank_limit():
    pool = [{"id": f"e{i}", "composer": "Brahms", "work": f"Work {i}", "title": "x"} for i in range(10)]
    assert len(rank("Brahms", pool)) == 5
    assert len(rank("Brahms", pool, limit=7)) == 7


def test_drafts_hidden_unless_enabled():
    assert "strauss-don-juan-draft" not in [e["id"] for e in Catalog(FIXTURE_CATALOG).excerpts("cello")]
    assert "strauss-don-juan-draft" in [e["id"] for e in Catalog(FIXTURE_CATALOG, include_drafts=True).excerpts("cello")]


# ---------------------------------------------------------------- endpoint


def test_identify_endpoint(client):
    response = client.post(
        "/v1/identify",
        json={"ocrText": "Symphony No. 2 Brahms Op. 73 Adagio non troppo", "instrument": "cello"},
    )
    assert response.status_code == 200, response.text
    candidates = response.json()["candidates"]
    assert candidates[0]["excerptId"] == "brahms-symphony-2-ii"
    assert set(candidates[0]) == {"excerptId", "score"}
    assert len(candidates) <= 5
    assert "strauss-don-juan-draft" not in [c["excerptId"] for c in candidates]


def test_identify_drafts_with_env(settings_factory):
    app = create_app(settings_factory(include_drafts=True))
    client = TestClient(app)
    response = client.post("/v1/identify", json={"ocrText": "Don Juan Strauss", "instrument": "cello"})
    assert response.json()["candidates"][0]["excerptId"] == "strauss-don-juan-draft"


def test_identify_unknown_instrument(client):
    response = client.post("/v1/identify", json={"ocrText": "Brahms", "instrument": "kazoo"})
    assert response.status_code == 400
    assert "kazoo" in response.json()["detail"]


def test_identify_instrument_without_catalogue(client):
    response = client.post("/v1/identify", json={"ocrText": "Brahms", "instrument": "tuba"})
    assert response.status_code == 200
    assert response.json() == {"candidates": []}


def test_identify_empty_text(client):
    response = client.post("/v1/identify", json={"ocrText": "", "instrument": "cello"})
    assert response.status_code == 200
    assert response.json() == {"candidates": []}


def test_identify_validation(client):
    response = client.post("/v1/identify", json={"ocrText": "Brahms"})
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], str)
    assert "instrument" in response.json()["detail"]


@pytest.mark.skipif(not list(REPO_CATALOG.glob("*.json")), reason="no real catalogue files in the repo yet")
def test_real_catalogue_loads(settings_factory):
    app = create_app(settings_factory(catalog_dir=REPO_CATALOG))
    client = TestClient(app)
    for path in sorted(REPO_CATALOG.glob("*.json")):
        instrument = path.stem
        data = json.loads(path.read_text())
        assert data["instrument"] == instrument
        response = client.post("/v1/identify", json={"ocrText": "Symphony", "instrument": instrument})
        assert response.status_code == 200
