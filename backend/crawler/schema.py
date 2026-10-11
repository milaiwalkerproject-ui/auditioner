"""The fixed JSON shapes Claude must fill in (structured outputs), plus helpers that
make a model answer safe to use downstream.

Design rules (see the claude-api skill, "JSON Schema Limitations"):
* every object lists all its properties as required and sets additionalProperties
  false; unknown values are empty strings / 0, never null or missing;
* no numeric or string constraints (not supported — checked in code instead);
* no "reasoning" field: thinking happens in the model's own thinking blocks.
"""

from __future__ import annotations

import copy
import re
from typing import Any

# Mirrors content/schema/catalog.schema.json $defs.instrument (a test checks this).
INSTRUMENT_IDS: tuple[str, ...] = (
    "violin", "viola", "cello", "double-bass", "harp", "flute", "piccolo", "oboe", "english-horn",
    "clarinet", "e-flat-clarinet", "bass-clarinet", "bassoon", "contrabassoon", "horn", "trumpet",
    "trombone", "bass-trombone", "tuba", "timpani", "percussion", "keyboard",
)
INSTRUMENT_ENUM: tuple[str, ...] = INSTRUMENT_IDS + ("other",)
LIST_COMPLETENESS: tuple[str, ...] = ("full", "partial_public", "works_only", "revealed_on_invitation", "unknown")
CATEGORIES: tuple[str, ...] = ("solo", "excerpt", "sight_reading", "chamber", "other")
LOCATION_TYPES: tuple[str, ...] = ("measures", "rehearsal_mark", "from_to_text", "whole", "unknown")

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LINE_ID_RE = re.compile(r"^L\d{4,6}$")


def _str(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _enum(values: tuple[str, ...], description: str) -> dict[str, Any]:
    return {"type": "string", "enum": list(values), "description": description}


def _obj(properties: dict[str, Any], description: str | None = None) -> dict[str, Any]:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "required": list(properties.keys()),
        "additionalProperties": False,
    }
    if description:
        schema["description"] = description
    return schema


LINE_IDS = {
    "type": "array",
    "items": {"type": "string"},
    "description": "Ids of the numbered source lines (e.g. \"L0012\") this fact was read from. Empty if it was not in the text.",
}

DATED_VALUE = _obj(
    {
        "value": _str("ISO date YYYY-MM-DD exactly as the source gives it, or \"\" when the source gives none."),
        "sourceLineIds": LINE_IDS,
    },
    "A date with the lines it was read from.",
)

LOCATION = _obj(
    {
        "type": _enum(LOCATION_TYPES, "measures = bar numbers given; rehearsal_mark = letters/numbers in boxes; from_to_text = words like 'beginning to the Allegro'; whole = the whole movement/work; unknown = nothing said."),
        "startText": _str("Start exactly as printed (e.g. \"mm. 1\", \"4 before [C]\", \"Beginning\"), or \"\"."),
        "endText": _str("End exactly as printed, or \"\"."),
        "startBar": {"type": "integer", "description": "Start bar number when the source prints one, else 0."},
        "endBar": {"type": "integer", "description": "End bar number when the source prints one, else 0."},
    },
    "Where in the part the excerpt is. Only what the source prints.",
)

ITEM = _obj(
    {
        "sourceLineIds": LINE_IDS,
        "rawText": _str("The source text for this item, verbatim (joined from the cited lines)."),
        "round": _str("Audition round as printed (\"Preliminary\", \"Final\", \"All rounds\"), or \"\"."),
        "category": _enum(CATEGORIES, "solo = concerto/solo piece; excerpt = orchestral excerpt; sight_reading; chamber; other."),
        "composer": _str("Composer as printed (\"Dvořák\", \"R. Strauss\"), or \"\"."),
        "work": _str("Work title as printed, without composer, movement or bars, or \"\"."),
        "catalogueNumber": _str("Opus / catalogue number if printed (\"Op. 67\", \"K. 550\", \"BWV 1007\"), else \"\"."),
        "movement": _str("Movement as printed (\"II\", \"Mvt. 2\", \"Finale\"), or \"\"."),
        "part": _str("Part named by the source (\"Cello\", \"Horn 1\", \"Solo cello\"), or \"\"."),
        "location": LOCATION,
        "notes": _str("Other printed conditions for this item (edition, 'with repeats', 'any concerto of your choice'), or \"\"."),
    },
    "One line of the repertoire list, as printed. Never add bars, marks or works the source does not print.",
)

VACANCY = _obj(
    {
        "orchestra": _str("Orchestra name as printed in the source, or \"\"."),
        "position": _str("Position as printed (\"Section Cello\", \"Principal Horn\", \"Assistant Principal Second Violin\"), or \"\"."),
        "instrument": _enum(INSTRUMENT_ENUM, "The catalogue instrument id this vacancy is for; \"other\" when none fits."),
        "chair": _str("Chair/seat detail as printed (\"2nd horn\", \"utility\"), or \"\"."),
        "applicationDeadline": DATED_VALUE,
        "auditionDates": {"type": "array", "items": DATED_VALUE, "description": "Each audition round date the source gives."},
        "listCompleteness": _enum(
            LIST_COMPLETENESS,
            "full = complete excerpt list with bars; partial_public = some excerpts public, more sent later; works_only = works named, no bars; revealed_on_invitation = list sent to invited candidates only; unknown.",
        ),
        "items": {"type": "array", "items": ITEM, "description": "Every repertoire item the source prints for this vacancy, in order."},
    },
    "One vacancy and its published repertoire list.",
)

EXTRACTION_SCHEMA = _obj(
    {
        "isAuditionNotice": {"type": "boolean", "description": "True when the source announces an orchestra audition or vacancy."},
        "language": _str("Main language of the source as a BCP-47 tag (\"en\", \"de\"), or \"\"."),
        "vacancies": {"type": "array", "items": VACANCY, "description": "One entry per vacancy the source describes; empty when there is none."},
        "sourceNotes": _str("Anything a reviewer should know about this source (two lists in one PDF, a page that is only a teaser, ...), or \"\"."),
    },
    "Everything the source says about auditions. Facts only; nothing inferred.",
)

TRIAGE_SCHEMA = _obj(
    {
        "hasAuditionContent": {"type": "boolean", "description": "True when the page is about orchestra auditions, vacancies or repertoire lists."},
        "pageHasRepertoireList": {"type": "boolean", "description": "True when the page text itself lists works/excerpts (not only links)."},
        "instruments": {"type": "array", "items": {"type": "string", "enum": list(INSTRUMENT_ENUM)}, "description": "Instruments with an open vacancy on the page."},
        "documentsToExtract": {"type": "array", "items": {"type": "string"}, "description": "Addresses from the given link list that look like repertoire or audition lists."},
        "notes": _str("One short line for the log."),
    },
    "Quick classification of an audition page.",
)


def extraction_schema() -> dict[str, Any]:
    return copy.deepcopy(EXTRACTION_SCHEMA)


def triage_schema() -> dict[str, Any]:
    return copy.deepcopy(TRIAGE_SCHEMA)


# ---------------------------------------------------------------- coercion helpers


def _s(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _i(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return max(0, value)
    if isinstance(value, float) and value.is_integer():
        return max(0, int(value))
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return 0


def _line_ids(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and LINE_ID_RE.match(item.strip()):
            out.append(item.strip())
    return out


def _dated(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {"value": "", "sourceLineIds": []}
    date = _s(value.get("value"))
    if date and not DATE_RE.match(date):
        date = ""
    return {"value": date, "sourceLineIds": _line_ids(value.get("sourceLineIds"))}


def coerce_location(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    kind = _s(value.get("type"))
    return {
        "type": kind if kind in LOCATION_TYPES else "unknown",
        "startText": _s(value.get("startText")),
        "endText": _s(value.get("endText")),
        "startBar": _i(value.get("startBar")),
        "endBar": _i(value.get("endBar")),
    }


def coerce_item(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    category = _s(value.get("category"))
    return {
        "sourceLineIds": _line_ids(value.get("sourceLineIds")),
        "rawText": _s(value.get("rawText")),
        "round": _s(value.get("round")),
        "category": category if category in CATEGORIES else "other",
        "composer": _s(value.get("composer")),
        "work": _s(value.get("work")),
        "catalogueNumber": _s(value.get("catalogueNumber")),
        "movement": _s(value.get("movement")),
        "part": _s(value.get("part")),
        "location": coerce_location(value.get("location")),
        "notes": _s(value.get("notes")),
    }


def coerce_vacancy(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    instrument = _s(value.get("instrument"))
    completeness = _s(value.get("listCompleteness"))
    dates = value.get("auditionDates")
    items = value.get("items")
    return {
        "orchestra": _s(value.get("orchestra")),
        "position": _s(value.get("position")),
        "instrument": instrument if instrument in INSTRUMENT_ENUM else "other",
        "chair": _s(value.get("chair")),
        "applicationDeadline": _dated(value.get("applicationDeadline")),
        "auditionDates": [_dated(d) for d in dates] if isinstance(dates, list) else [],
        "listCompleteness": completeness if completeness in LIST_COMPLETENESS else "unknown",
        "items": [coerce_item(i) for i in items] if isinstance(items, list) else [],
    }


def coerce_extraction(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    vacancies = value.get("vacancies")
    return {
        "isAuditionNotice": bool(value.get("isAuditionNotice", False)),
        "language": _s(value.get("language")),
        "vacancies": [coerce_vacancy(v) for v in vacancies] if isinstance(vacancies, list) else [],
        "sourceNotes": _s(value.get("sourceNotes")),
    }


def coerce_triage(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    instruments = value.get("instruments")
    documents = value.get("documentsToExtract")
    return {
        "hasAuditionContent": bool(value.get("hasAuditionContent", False)),
        "pageHasRepertoireList": bool(value.get("pageHasRepertoireList", False)),
        "instruments": [i for i in instruments if isinstance(i, str) and i in INSTRUMENT_ENUM] if isinstance(instruments, list) else [],
        "documentsToExtract": [d.strip() for d in documents if isinstance(d, str) and d.strip()] if isinstance(documents, list) else [],
        "notes": _s(value.get("notes")),
    }
