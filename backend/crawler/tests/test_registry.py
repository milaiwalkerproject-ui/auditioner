from __future__ import annotations

import json
from pathlib import Path

import pytest

from crawler.registry import RegistryError, load_registry, parse_registry, select

from .conftest import FIXTURE_REGISTRY


def test_loads_object_form_and_entries():
    registry = load_registry(FIXTURE_REGISTRY, strict=True)
    assert [o.id for o in registry.orchestras] == ["example-phil", "example-youth"]
    phil = registry.get("example-phil")
    assert phil is not None
    assert phil.start_url == "https://www.example-phil.org/auditions"
    assert phil.hosts == {"www.example-phil.org"}
    assert registry.get("example-youth").tutti_org_id == "example-youth-tutti"
    assert registry.hosts == {"www.example-phil.org", "jugend.example.de"}
    assert registry.version == "test"


def test_bare_list_form_is_accepted():
    data = json.loads(FIXTURE_REGISTRY.read_text())["orchestras"]
    registry = parse_registry(data, strict=True)
    assert len(registry.orchestras) == 2


def test_bad_entries_are_skipped_with_reasons_not_crashes():
    data = [
        {"id": "Bad Id", "name": "x", "country": "US", "region": "north-america", "type": "professional", "source": "https://a.example/", "asOf": "2026-01-01"},
        {"id": "no-region", "name": "x", "country": "US", "region": "mars", "type": "professional", "source": "https://a.example/", "asOf": "2026-01-01"},
        {"id": "bad-url", "name": "x", "country": "US", "region": "uk", "type": "youth", "auditionsUrl": "ftp://a.example/x", "source": "https://a.example/", "asOf": "2026-01-01"},
        {"id": "fine", "name": "Fine", "country": "GB", "region": "uk", "type": "youth", "auditionsUrl": "https://fine.example/auditions", "source": "https://fine.example/", "asOf": "2026-01-01"},
        {"id": "fine", "name": "Dup", "country": "GB", "region": "uk", "type": "youth", "auditionsUrl": "https://fine.example/auditions", "source": "https://fine.example/", "asOf": "2026-01-01"},
        {"id": "no-address", "name": "No address", "country": "GB", "region": "uk", "type": "youth", "source": "https://x.example/", "asOf": "2026-01-01"},
        "not an object",
    ]
    registry = parse_registry(data)
    assert [o.id for o in registry.orchestras] == ["fine", "no-address"]
    joined = "\n".join(registry.problems)
    assert "kebab-case" in joined
    assert "region" in joined
    assert "http(s)" in joined
    assert "duplicate id" in joined
    assert "not an object" in joined
    assert "nothing to read" not in joined  # a missing address is a note, not a problem
    assert any("no-address" in note and "nothing to read" in note for note in registry.notes)
    with pytest.raises(RegistryError):
        parse_registry(data, strict=True)


def test_wrong_shapes_raise(tmp_path: Path):
    with pytest.raises(RegistryError):
        parse_registry({"nope": []})
    with pytest.raises(RegistryError):
        parse_registry("string")
    with pytest.raises(RegistryError):
        load_registry(tmp_path / "missing.json")
    broken = tmp_path / "broken.json"
    broken.write_text("{not json")
    with pytest.raises(RegistryError):
        load_registry(broken)


def test_select_filters_and_limits():
    registry = load_registry(FIXTURE_REGISTRY)
    assert [o.id for o in select(registry, orchestra_id="example-youth")] == ["example-youth"]
    assert [o.id for o in select(registry, limit=1)] == ["example-phil"]
    assert select(registry, orchestra_id="nobody") == []
