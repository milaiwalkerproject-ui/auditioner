#!/usr/bin/env python3
"""Publish imported (provenanceType "imported") excerpts in the given catalogue files.

  python3 content/review/publish_imported.py content/catalog/horn.json ...

Milai decided on 2026-10-10 (excerpt-review page, "Brass import") to publish the
BrassXcerpts import now. The app labels these "Imported — bars not yet checked"
(provenanceType + the location note); bar ranges still need re-checking against
the parts (PLAN.md A4).
"""
import json
import pathlib
import sys

for name in sys.argv[1:]:
    path = pathlib.Path(name)
    data = json.loads(path.read_text())
    n = 0
    for ex in data["excerpts"]:
        if ex.get("provenanceType") == "imported" and ex.get("listingStatus") != "published":
            ex["listingStatus"] = "published"
            n += 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"{path.name}: published {n}")
