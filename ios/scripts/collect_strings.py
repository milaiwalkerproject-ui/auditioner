#!/usr/bin/env python3
"""Collect every localizable string the Swift compiler found (the .stringsdata files
Xcode writes when SWIFT_EMIT_LOC_STRINGS=YES) and compare them with the String Catalog.

Usage (CI, after a build):
    python3 ios/scripts/collect_strings.py build/DerivedData ios/Auditioner/Localizable.xcstrings

Prints how many keys the app uses, how many are missing from the catalogue and, per
language, how many are untranslated. With --dump it also prints the keys (with the
compiler's comments) as gzip+base64 between markers, so they can be read from the CI
log (artifacts can't be downloaded from the cloud coding session).
"""
from __future__ import annotations

import base64
import gzip
import json
import sys
from pathlib import Path

LANGUAGES = ["es", "zh-Hans", "zh-Hant", "it", "ru", "ja", "ko", "de", "fr", "pt-BR"]


def collect(derived: Path) -> dict[str, dict]:
    keys: dict[str, dict] = {}
    for path in derived.rglob("*.stringsdata"):
        if "AuditionerTests" in str(path):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        source = Path(data.get("source", "")).name
        for table, entries in (data.get("tables") or {}).items():
            if table != "Localizable":
                continue
            for entry in entries:
                key = entry.get("key")
                if not key:
                    continue
                slot = keys.setdefault(key, {"comment": "", "files": []})
                if entry.get("comment") and not slot["comment"]:
                    slot["comment"] = entry["comment"]
                if source and source not in slot["files"]:
                    slot["files"].append(source)
    return keys


def main(argv: list[str]) -> int:
    dump = "--dump" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) < 2:
        print(__doc__)
        return 2
    derived, catalog_path = Path(args[0]), Path(args[1])
    keys = collect(derived)
    catalog = {"strings": {}}
    if catalog_path.exists():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    missing = sorted(k for k in keys if k not in strings)
    stale = sorted(k for k in strings if k not in keys and strings[k].get("extractionState") != "manual")
    print(f"localizable strings in the app: {len(keys)}")
    print(f"missing from Localizable.xcstrings: {len(missing)}")
    print(f"in the catalogue but no longer used: {len(stale)}")
    for lang in LANGUAGES:
        untranslated = sum(
            1 for k in keys
            if not (((strings.get(k) or {}).get("localizations") or {}).get(lang) or {})
        )
        print(f"  {lang}: {untranslated} untranslated")
    for key in missing[:40]:
        print(f"  + {key!r}")
    if dump:
        blob = base64.b64encode(gzip.compress(json.dumps(keys, ensure_ascii=False, sort_keys=True).encode("utf-8"))).decode()
        print("==== STRINGS BEGIN ====")
        for i in range(0, len(blob), 100):
            print(blob[i:i + 100])
        print("==== STRINGS END ====")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
