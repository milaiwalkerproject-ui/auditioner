#!/usr/bin/env python3
"""Machine translations of approved excerpt notes (PLAN A7b).

    python3 content/translations/notes_tools.py source      # write _source.json
    python3 content/translations/notes_tools.py check [lang] [--strict]  # verify <lang>.json files

_source.json lists every approved note (prose with reviewStatus "approved") with a
sha256 of its English text and the terms that must survive translation unchanged.
<lang>.json mirrors it: {"language", "origin": "ai", "machineTranslated": true,
"generatedAt", "notes": {excerptId: {field: {"text", "sourceSha256"}}}}.

The check refuses (exit 1) a current translation (one the app would ship) that is
empty, identical to the English, or that changes any number or any protected term
(the excerpt's tempo marking, score words such as "Andante con moto"). Missing and
stale translations (the English changed since) are listed as notes shown in English
for now; they fail only with --strict, which translators use to finish a language. The app ships only translations whose sourceSha256 matches
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


MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December"]
# Chinese, Japanese and Korean write a month as a number (8月, 8월), so for them a month
# name in the English may become that number; nothing else may be added or changed.
NUMERIC_MONTH_LANGUAGES = {"zh-Hans", "zh-Hant", "ja", "ko"}


def expected_numbers(text: str, lang: str) -> list[list[str]]:
    """The digit sequences a faithful translation may contain, as sorted lists."""
    plain = sorted(NUMBER.findall(text))
    if lang not in NUMERIC_MONTH_LANGUAGES:
        return [plain]
    months = [str(i + 1) for i, name in enumerate(MONTHS) for _ in re.findall(rf"\b{name}\b", text)]
    return [plain, sorted(plain + months)] if months else [plain]


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


def check(lang: str, source: dict) -> tuple[list[str], list[str]]:
    """(errors, notices) for one language.

    Errors are translations the app would ship that are wrong: a broken file header, or a
    current translation (its sourceSha256 matches today's English) that is empty, still
    English, or changed a number or a protected term. Notices are notes the app will show
    in English for now: missing, stale (the English was corrected or extended since) or no
    longer approved. content/sync_to_app.py never ships those, so a correction to an English
    note never has to wait for ten re-translations.
    """
    path = HERE / f"{lang}.json"
    if not path.exists():
        return [], [f"{lang}: no {path.name} — every note shows in English"]
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    notices: list[str] = []
    if data.get("language") != lang:
        errors.append(f"{lang}: language field is {data.get('language')!r}")
    if data.get("origin") != "ai" or data.get("machineTranslated") is not True:
        errors.append(f"{lang}: origin must be 'ai' and machineTranslated true")
    got = data.get("notes") or {}
    for eid, fields in source["notes"].items():
        for field, src in fields.items():
            t = (got.get(eid) or {}).get(field)
            where = f"{lang}: {eid}.{field}"
            if not t:
                notices.append(f"{where}: missing (shows in English)")
                continue
            if t.get("sourceSha256") != src["sourceSha256"]:
                notices.append(f"{where}: stale — the English changed since it was translated (shows in English)")
                continue
            text = (t.get("text") or "").strip()
            if not text:
                errors.append(f"{where}: empty")
                continue
            if text == src["text"].strip():
                errors.append(f"{where}: identical to the English")
            if sorted(NUMBER.findall(text)) not in expected_numbers(src["text"], lang):
                errors.append(f"{where}: numbers differ {sorted(NUMBER.findall(src['text']))} -> {sorted(NUMBER.findall(text))}")
            for term in src["keepUnchanged"]:
                if src["text"].count(term) and term not in text:
                    errors.append(f"{where}: lost the original-language term {term!r}")
    for eid, fields in got.items():
        for field in fields:
            if field not in (source["notes"].get(eid) or {}):
                notices.append(f"{lang}: {eid}.{field}: not an approved English note any more (not shipped; remove it)")
    return errors, notices


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
    strict = "--strict" in argv
    langs = [a for a in argv[1:] if not a.startswith("--")] or [l for l in LANGUAGES if (HERE / f"{l}.json").exists()]
    errors: list[str] = []
    notices: list[str] = []
    for lang in langs:
        e, n = check(lang, source)
        errors += e
        notices += n
        if not e and not n:
            print(f"{lang}: ok")
        else:
            print(f"{lang}: {len(e)} errors, {len(n)} notes shown in English for now")
    for p in errors:
        print("  !", p)
    for p in notices:
        print("  ·", p)
    # Errors always fail. Notices fail only with --strict (translators use it to finish a language).
    return 1 if errors or (strict and notices) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
