#!/usr/bin/env python3
"""Machine translations of approved excerpt notes (PLAN A7b).

    python3 content/translations/notes_tools.py source      # write _source.json
    python3 content/translations/notes_tools.py check [lang] # verify <lang>.json files

_source.json lists every approved note (prose with reviewStatus "approved") with a
sha256 of its English text and the terms that must survive translation unchanged.
<lang>.json mirrors it: {"language", "origin": "ai", "machineTranslated": true,
"generatedAt", "notes": {excerptId: {field: {"text", "sourceSha256"}}}}.

The check refuses (exit 1) a translation that is stale (English changed since),
empty, identical to the English, or that changes any number or any protected term
(composer and work names, the excerpt's tempo marking, score words such as
"Andante con moto"). The app ships only translations whose sourceSha256 matches
the current English text; content/sync_to_app.py drops the rest.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "content" / "catalog"
HERE = Path(__file__).resolve().parent
LANGUAGES = ["es", "zh-Hans", "zh-Hant", "it", "ru", "ja", "ko", "de", "fr", "pt-BR"]
FIELDS = ["history", "technique", "pitfalls", "practiceTips"]

# Score and performance words that stay in the original language (A7) whenever the
# English note uses them. Matched case-sensitively as whole words/phrases.
SCORE_TERMS = [
    "Andante con moto", "Adagio non troppo", "Poco allegretto", "Allegro con grazia",
    "Andantino in modo di canzona", "Allegro giocoso", "Allegro con brio",
    "Andante", "Andantino", "Adagio", "Allegro", "Allegretto", "Presto", "Largo", "Lento",
    "Moderato", "Vivace", "Scherzo", "Trio", "Offertorio",
    "pizzicato", "arco", "spiccato", "sautillé", "staccato", "legato", "tenuto", "marcato",
    "sul ponticello", "sul tasto", "col legno", "sforzando", "subito", "dolce", "espressivo",
    "cantabile", "crescendo", "diminuendo", "ritardando", "rallentando", "accelerando",
    "tutti", "divisi", "con sordino", "senza sordino",
]
NUMBER = re.compile(r"\d+")


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def protected_terms(excerpt: dict, text: str) -> list[str]:
    terms: set[str] = set()
    tm = excerpt.get("tempoMarking") or {}
    if tm.get("status") == "verified" and isinstance(tm.get("value"), str):
        terms.add(tm["value"])
    for term in SCORE_TERMS:
        if re.search(rf"(?<![\w-]){re.escape(term)}(?![\w-])", text):
            terms.add(term)
    # Keep only terms actually in the English note; longest first so the check is strict.
    return sorted((t for t in terms if t in text), key=lambda t: (-len(t), t))


def build_source() -> dict:
    notes: dict[str, dict] = {}
    for path in sorted(CATALOG.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for e in data.get("excerpts", []):
            prose = e.get("prose") or {}
            for field in FIELDS:
                p = prose.get(field)
                if not (isinstance(p, dict) and p.get("reviewStatus") == "approved" and (p.get("text") or "").strip()):
                    continue
                text = p["text"]
                notes.setdefault(e["id"], {})[field] = {
                    "text": text,
                    "sourceSha256": sha(text),
                    "keepUnchanged": protected_terms(e, text),
                    "context": {"composer": e.get("composer"), "work": e.get("work"), "title": e.get("title")},
                }
    return {"language": "en", "notes": notes}


def check(lang: str, source: dict) -> list[str]:
    path = HERE / f"{lang}.json"
    if not path.exists():
        return [f"{lang}: no {path.name}"]
    data = json.loads(path.read_text(encoding="utf-8"))
    problems: list[str] = []
    if data.get("language") != lang:
        problems.append(f"{lang}: language field is {data.get('language')!r}")
    if data.get("origin") != "ai" or data.get("machineTranslated") is not True:
        problems.append(f"{lang}: origin must be 'ai' and machineTranslated true")
    got = data.get("notes") or {}
    for eid, fields in source["notes"].items():
        for field, src in fields.items():
            t = (got.get(eid) or {}).get(field)
            where = f"{lang}: {eid}.{field}"
            if not t:
                problems.append(f"{where}: missing")
                continue
            text = (t.get("text") or "").strip()
            if t.get("sourceSha256") != src["sourceSha256"]:
                problems.append(f"{where}: stale (English changed since it was translated)")
            if not text:
                problems.append(f"{where}: empty")
                continue
            if text == src["text"].strip():
                problems.append(f"{where}: identical to the English")
            if sorted(NUMBER.findall(text)) != sorted(NUMBER.findall(src["text"])):
                problems.append(f"{where}: numbers differ {sorted(NUMBER.findall(src['text']))} -> {sorted(NUMBER.findall(text))}")
            for term in src["keepUnchanged"]:
                if src["text"].count(term) and term not in text:
                    problems.append(f"{where}: lost the original-language term {term!r}")
    for eid, fields in got.items():
        for field in fields:
            if field not in (source["notes"].get(eid) or {}):
                problems.append(f"{lang}: {eid}.{field}: not an approved note (remove it)")
    return problems


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("source", "check"):
        print(__doc__)
        return 2
    source = build_source()
    if argv[0] == "source":
        (HERE / "_source.json").write_text(json.dumps(source, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        n = sum(len(f) for f in source["notes"].values())
        print(f"_source.json: {n} approved notes in {len(source['notes'])} excerpts")
        return 0
    langs = argv[1:] or [l for l in LANGUAGES if (HERE / f"{l}.json").exists()]
    problems: list[str] = []
    for lang in langs:
        p = check(lang, source)
        problems += p
        print(f"{lang}: {'ok' if not p else f'{len(p)} problems'}")
    for p in problems:
        print("  !", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
