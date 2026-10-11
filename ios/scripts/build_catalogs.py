#!/usr/bin/env python3
"""Build the app's String Catalogs from the translation sources in ios/l10n/.

    python3 ios/scripts/build_catalogs.py [--check]

Sources (all committed):
  ios/l10n/_keys.json            every key the app uses (from CI's "Strings for
                                 translation" step: collect_strings.py --dump)
  ios/l10n/<lang>.json           UI translations, {key: text | plural forms}
  ios/l10n/topup/<lang>.json     later additions, merged into <lang>.json here
  ios/l10n/topup/infoplist-<lang>.json   Info.plist strings (permission prompts…)

Writes ios/Auditioner/Localizable.xcstrings (rebuilt from scratch, so keys the app
no longer uses disappear) and adds the translations to
ios/Auditioner/InfoPlist.xcstrings. Every translation goes through
merge_translations.py's checks; a rejected one is left out and the app shows
English there. --check exits 1 if anything is rejected or untranslated.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
L10N = ROOT / "ios" / "l10n"
TOPUP = L10N / "topup"
LOCALIZABLE = ROOT / "ios" / "Auditioner" / "Localizable.xcstrings"
INFOPLIST = ROOT / "ios" / "Auditioner" / "InfoPlist.xcstrings"
LANGUAGES = ["es", "zh-Hans", "zh-Hant", "it", "ru", "ja", "ko", "de", "fr", "pt-BR"]


def dump(path: Path, data: dict, *, xcstrings: bool = False) -> None:
    if xcstrings:
        text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    else:
        text = json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True)
    path.write_text(text + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    check = "--check" in argv
    keys: dict = json.loads((L10N / "_keys.json").read_text(encoding="utf-8"))
    problems: list[str] = []

    # 1. Fold top-ups into each language file and drop keys the app no longer uses.
    for lang in LANGUAGES:
        path = L10N / f"{lang}.json"
        data: dict = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        extra = TOPUP / f"{lang}.json"
        if extra.exists():
            data.update(json.loads(extra.read_text(encoding="utf-8")))
        kept = {k: v for k, v in data.items() if k in keys}
        missing = [k for k in keys if k not in kept]
        if missing:
            problems.append(f"{lang}: {len(missing)} keys untranslated, e.g. {missing[0]!r}")
        if not check:
            dump(path, kept)

    # 2. Rebuild Localizable.xcstrings from scratch through the validator.
    if not check:
        dump(LOCALIZABLE, {"sourceLanguage": "en", "strings": {}, "version": "1.0"}, xcstrings=True)
    args = [sys.executable, str(ROOT / "ios/scripts/merge_translations.py"), str(L10N / "_keys.json"), str(L10N),
            "--catalog", str(LOCALIZABLE)] + (["--check"] if check else [])
    result = subprocess.run(args, capture_output=True, text=True)
    print(result.stdout, end="")
    problems += [line.strip() for line in result.stdout.splitlines() if line.strip().startswith("!")]

    # 3. Info.plist strings.
    info: dict = json.loads(INFOPLIST.read_text(encoding="utf-8"))
    for lang in LANGUAGES:
        path = TOPUP / f"infoplist-{lang}.json"
        if not path.exists():
            problems.append(f"{lang}: no {path.name}")
            continue
        values: dict = json.loads(path.read_text(encoding="utf-8"))
        for key, entry in info["strings"].items():
            text = (values.get(key) or "").strip()
            if not text:
                problems.append(f"{lang}: Info.plist {key} untranslated")
                continue
            entry.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": text}}
    if not check:
        dump(INFOPLIST, info, xcstrings=True)

    for p in problems:
        print("  !", p)
    print("ok" if not problems else f"{len(problems)} problems")
    return 1 if (check and problems) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
