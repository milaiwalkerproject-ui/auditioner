from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from crawler.schema import (
    INSTRUMENT_IDS,
    coerce_extraction,
    coerce_triage,
    extraction_schema,
    triage_schema,
)

CATALOG_SCHEMA = Path(__file__).resolve().parents[4] / "content" / "schema" / "catalog.schema.json"

UNSUPPORTED = {"minimum", "maximum", "multipleOf", "minLength", "maxLength", "pattern", "minItems", "maxItems", "$ref", "oneOf"}


def _walk(node: Any, path: str = "$"):
    if isinstance(node, dict):
        yield path, node
        for key, value in node.items():
            yield from _walk(value, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _walk(value, f"{path}[{index}]")


def test_instrument_ids_match_the_catalogue_schema():
    if not CATALOG_SCHEMA.exists():
        return
    schema = json.loads(CATALOG_SCHEMA.read_text())
    assert list(INSTRUMENT_IDS) == schema["$defs"]["instrument"]["enum"]


def test_schemas_stay_inside_structured_output_limits():
    for schema in (extraction_schema(), triage_schema()):
        for path, node in _walk(schema):
            assert not (set(node) & UNSUPPORTED), f"{path} uses {set(node) & UNSUPPORTED}"
            if node.get("type") == "object":
                assert node.get("additionalProperties") is False, path
                assert sorted(node["required"]) == sorted(node["properties"]), path
            assert "reasoning" not in node.get("properties", {}), path


def test_coercion_fills_sentinels_and_drops_junk():
    data = coerce_extraction(
        {
            "isAuditionNotice": True,
            "vacancies": [
                {
                    "position": " Section Cello ",
                    "instrument": "violoncello",
                    "applicationDeadline": {"value": "15 Nov 2026", "sourceLineIds": ["L0002", "nope", 3]},
                    "auditionDates": "not a list",
                    "listCompleteness": "complete",
                    "items": [
                        {"composer": "Quill", "category": "excerpt", "location": {"type": "measures", "startBar": "1", "endBar": 106.0}, "sourceLineIds": ["L0003"]},
                        "garbage",
                    ],
                }
            ],
        }
    )
    vacancy = data["vacancies"][0]
    assert vacancy["position"] == "Section Cello"
    assert vacancy["instrument"] == "other"
    assert vacancy["applicationDeadline"] == {"value": "", "sourceLineIds": ["L0002"]}
    assert vacancy["auditionDates"] == []
    assert vacancy["listCompleteness"] == "unknown"
    item = vacancy["items"][0]
    assert item["location"] == {"type": "measures", "startText": "", "endText": "", "startBar": 1, "endBar": 106}
    assert item["work"] == "" and item["round"] == ""
    assert vacancy["items"][1]["category"] == "other" and vacancy["items"][1]["sourceLineIds"] == []
    assert coerce_extraction("nonsense")["vacancies"] == []


def test_triage_coercion():
    data = coerce_triage({"hasAuditionContent": 1, "instruments": ["cello", "kazoo"], "documentsToExtract": ["https://x/a.pdf", 5]})
    assert data == {"hasAuditionContent": True, "pageHasRepertoireList": False, "instruments": ["cello"], "documentsToExtract": ["https://x/a.pdf"], "notes": ""}
