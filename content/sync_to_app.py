#!/usr/bin/env python3
"""Copy content/catalog/<instrument>.json into the iOS app bundle as
ios/Auditioner/Resources/Catalog/catalog-<instrument>.json, and checked MusicXML
transcriptions from content/musicxml/ into ios/Auditioner/Resources/MusicXML/.

  python3 content/sync_to_app.py          write the copies
  python3 content/sync_to_app.py --check  fail if the copies have drifted (CI)
"""
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
