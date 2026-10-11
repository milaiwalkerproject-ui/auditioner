#!/usr/bin/env python3
"""Merge machine translations into the app's String Catalog, refusing any that
would break at runtime.

Usage:
    python3 ios/scripts/merge_translations.py KEYS.json TRANSLATIONS_DIR \
        [--catalog ios/Auditioner/Localizable.xcstrings] [--check] [--only LANG]

KEYS.json         every key the app uses, as dumped by collect_strings.py
                  ({key: {"comment": str, "files": [str]}}).
TRANSLATIONS_DIR  one <lang>.json per language: {key: "text"} or, for keys with
                  exactly one format argument that is an integer,
                  {key: {"one": "...", "other": "...", ...}} (CLDR plural
                  categories of that language).

A translation is accepted only if it consumes exactly the same format arguments
as the English key (same types; positional %1$@ forms allowed for reordering),
keeps "%%" literals, and is not empty. Rejected entries are left out, so the app
shows English there rather than garbled or crashing text. --check reports and
writes nothing. --only LANG checks/merges just that language (for translators).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

LANGUAGES = ["es", "zh-Hans", "zh-Hant", "it", "ru", "ja", "ko", "de", "fr", "pt-BR"]

# CLDR cardinal plural categories iOS uses for each language (integers only).
PLURAL_CATEGORIES = {
    "es": {"one", "many", "other"},
    "it": {"one", "many", "other"},
    "fr": {"one", "many", "other"},
    "pt-BR": {"one", "many", "other"},
    "de": {"one", "other"},
    "ru": {"one", "few", "many", "other"},
    "ja": {"other"},
    "ko": {"other"},
    "zh-Hans": {"other"},
    "zh-Hant": {"other"},
}
REQUIRED_PLURALS = {
    "es": {"one", "other"},
    "it": {"one", "other"},
    "fr": {"one", "other"},
    "pt-BR": {"one", "other"},
    "de": {"one", "other"},
    "ru": {"one", "few", "many", "other"},
    "ja": {"other"},
    "ko": {"other"},
    "zh-Hans": {"other"},
    "zh-Hant": {"other"},
}

SPEC = re.compile(
    r"%(?:(?P<pos>\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDuUxXoOfFeEgGcCsSpaA%])"
)


def specifiers(text: str) -> tuple[list[tuple[int | None, str]], int]:
    """([(position or None, normalised type)], count of %% literals)."""
    out: list[tuple[int | None, str]] = []
    literals = 0
    for m in SPEC.finditer(text):
        conv = m.group("conv")
        if conv == "%":
            literals += 1
            continue
        if conv in "dDuUxXoOcC":
            kind = "int"
        elif conv in "fFeEgGaA":
            kind = "float"
        else:
            kind = "object"
        pos = int(m.group("pos")) if m.group("pos") else None
        out.append((pos, kind))
    return out, literals


def argument_types(text: str) -> list[str]:
    specs, _ = specifiers(text)
    if any(p is not None for p, _ in specs):
        by_pos: dict[int, str] = {}
        for p, kind in specs:
            if p is not None:
                by_pos[p] = kind
        return [by_pos[i] for i in sorted(by_pos)]
    return [kind for _, kind in specs]


def check_form(source: str, form: str) -> str | None:
    """None when `form` is a safe translation of `source`, else the reason."""
    if not form.strip():
        return "empty"
    src_specs, src_lit = specifiers(source)
    dst_specs, dst_lit = specifiers(form)
    if src_lit != dst_lit:
        return "%% literal count differs"
    src_types = [kind for _, kind in src_specs]
    positional = [p for p, _ in dst_specs if p is not None]
    if positional and len(positional) != len(dst_specs):
        return "mixes positional and plain specifiers"
    if positional:
        if sorted(positional) != list(range(1, len(src_types) + 1)):
            return f"positional arguments {sorted(positional)} don't match {len(src_types)} arguments"
        for p, kind in dst_specs:
            if src_types[p - 1] != kind:
                return f"argument {p} type {kind} != {src_types[p - 1]}"
        return None
    dst_types = [kind for _, kind in dst_specs]
    if dst_types != src_types:
        return f"arguments {dst_types} != {src_types}"
    return None


def pluralizable(source: str) -> bool:
    types = argument_types(source)
    return len(types) == 1 and types[0] == "int"


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    args = [a for a in argv if not a.startswith("--")]
    catalog_path = Path("ios/Auditioner/Localizable.xcstrings")
    if "--catalog" in argv:
        catalog_path = Path(argv[argv.index("--catalog") + 1])
        args = [a for a in args if a != str(catalog_path)]
    languages = LANGUAGES
    if "--only" in argv:
        only = argv[argv.index("--only") + 1]
        args = [a for a in args if a != only]
        languages = [only]
    if len(args) < 2:
        print(__doc__)
        return 2
    keys: dict[str, dict] = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    tdir = Path(args[1])
    catalog = json.loads(catalog_path.read_text(encoding="utf-8")) if catalog_path.exists() else {}
    catalog.setdefault("sourceLanguage", "en")
    catalog.setdefault("version", "1.0")
    strings: dict = catalog.setdefault("strings", {})

    problems: list[str] = []
    accepted: dict[str, int] = {}
    for key, info in keys.items():
        entry = strings.setdefault(key, {})
        if info.get("comment") and not entry.get("comment"):
            entry["comment"] = info["comment"]

    for lang in languages:
        path = tdir / f"{lang}.json"
        if not path.exists():
            problems.append(f"{lang}: no {path.name}")
            continue
        data: dict = json.loads(path.read_text(encoding="utf-8"))
        accepted[lang] = 0
        for key, value in data.items():
            if key not in keys:
                problems.append(f"{lang}: unknown key {key!r}")
                continue
            entry = strings[key]
            locs = entry.setdefault("localizations", {})
            if isinstance(value, str):
                reason = check_form(key, value)
                if reason:
                    problems.append(f"{lang}: {key!r}: {reason}")
                    locs.pop(lang, None)
                    continue
                locs[lang] = unit(value)
            elif isinstance(value, dict):
                if not pluralizable(key):
                    problems.append(f"{lang}: {key!r}: plural forms given but the key has no single integer argument")
                    locs.pop(lang, None)
                    continue
                cats = set(value)
                bad = cats - PLURAL_CATEGORIES[lang]
                missing = REQUIRED_PLURALS[lang] - cats
                if bad or missing:
                    problems.append(f"{lang}: {key!r}: plural categories {sorted(cats)} (bad {sorted(bad)}, missing {sorted(missing)})")
                    locs.pop(lang, None)
                    continue
                reasons = [r for r in (check_form(key, v) if isinstance(v, str) else "not text" for v in value.values()) if r]
                if reasons:
                    problems.append(f"{lang}: {key!r}: {reasons[0]}")
                    locs.pop(lang, None)
                    continue
                if cats == {"other"}:
                    locs[lang] = unit(value["other"])
                else:
                    locs[lang] = {"variations": {"plural": {c: unit(v) for c, v in sorted(value.items())}}}
            else:
                problems.append(f"{lang}: {key!r}: value is neither text nor plural forms")
                continue
            if not entry["localizations"]:
                entry.pop("localizations")
            accepted[lang] += 1

    for lang in languages:
        have = sum(1 for k in keys if lang in ((strings.get(k) or {}).get("localizations") or {}))
        print(f"{lang}: {accepted.get(lang, 0)} accepted, {len(keys) - have} keys still untranslated")
    for p in problems:
        print("  !", p)
    if not check_only:
        catalog_path.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {catalog_path}")
    return 1 if (problems and check_only) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
