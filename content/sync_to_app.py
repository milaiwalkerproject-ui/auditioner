#!/usr/bin/env python3
"""Copy content/catalog/<instrument>.json into the iOS app bundle as
ios/Auditioner/Resources/Catalog/catalog-<instrument>.json, checked MusicXML
transcriptions from content/musicxml/ into ios/Auditioner/Resources/MusicXML/, and
machine translations of approved notes (content/translations/<lang>.json) into
ios/Auditioner/Resources/Translations/notes-<lang>.json — only the translations
whose sourceSha256 still matches the current English note (PLAN A7b).

  python3 content/sync_to_app.py          write the copies
  python3 content/sync_to_app.py --check  fail if the copies have drifted (CI)
"""
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parent
PAIRS = []
for src in sorted((ROOT / "catalog").glob("*.json")):
    PAIRS.append((src, REPO / "ios/Auditioner/Resources/Catalog" / f"catalog-{src.name}"))
for src in sorted((ROOT / "musicxml").glob("*.musicxml")):
    PAIRS.append((src, REPO / "ios/Auditioner/Resources/MusicXML" / src.name))

check = "--check" in sys.argv
drift = []
for src, dst in PAIRS:
    if check:
        if not dst.exists() or dst.read_bytes() != src.read_bytes():
            drift.append(str(dst.relative_to(REPO)))
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())


def fresh_translations(path: pathlib.Path, english: dict) -> bytes:
    """The app copy of one language: only notes whose English hasn't changed since."""
    data = json.loads(path.read_text(encoding="utf-8"))
    kept: dict = {}
    for eid, fields in (data.get("notes") or {}).items():
        for field, t in fields.items():
            src = english.get((eid, field))
            if src is not None and t.get("sourceSha256") == hashlib.sha256(src.encode("utf-8")).hexdigest():
                kept.setdefault(eid, {})[field] = t["text"]
    out = {"language": data.get("language"), "origin": "ai", "machineTranslated": True,
           "generatedAt": data.get("generatedAt"), "notes": kept}
    return (json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")


english_notes: dict = {}
for src in sorted((ROOT / "catalog").glob("*.json")):
    for e in json.loads(src.read_text(encoding="utf-8")).get("excerpts", []):
        for field, p in (e.get("prose") or {}).items():
            if isinstance(p, dict) and p.get("reviewStatus") == "approved" and p.get("text"):
                english_notes[(e["id"], field)] = p["text"]
translation_names = set()
for src in sorted((ROOT / "translations").glob("*.json")):
    if src.name.startswith("_"):
        continue
    dst = REPO / "ios/Auditioner/Resources/Translations" / f"notes-{src.name}"
    translation_names.add(dst.name)
    body = fresh_translations(src, english_notes)
    if check:
        if not dst.exists() or dst.read_bytes() != body:
            drift.append(str(dst.relative_to(REPO)))
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(body)
for dst in (REPO / "ios/Auditioner/Resources/Translations").glob("notes-*.json"):
    if dst.name not in translation_names:
        if check:
            drift.append(f"{dst.relative_to(REPO)} (no source)")
        else:
            dst.unlink()

# copies in the app that no longer have a source
for folder, pattern, prefix in (("Catalog", "catalog-*.json", "catalog-"), ("MusicXML", "*.musicxml", "")):
    for dst in (REPO / "ios/Auditioner/Resources" / folder).glob(pattern):
        name = dst.name[len(prefix):]
        src_dir = ROOT / ("catalog" if folder == "Catalog" else "musicxml")
        if not (src_dir / name).exists():
            if check:
                drift.append(f"{dst.relative_to(REPO)} (no source)")
            else:
                dst.unlink()

if check and drift:
    print("Out of sync — run python3 content/sync_to_app.py:\n  " + "\n  ".join(drift))
    sys.exit(1)
print("in sync" if check else f"synced {len(PAIRS)} files")
