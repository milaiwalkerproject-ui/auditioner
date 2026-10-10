#!/usr/bin/env python3
"""Apply Milai's decisions from the private "Excerpt review" page to a catalogue file.

  python3 content/review/apply_review.py content/catalog/cello.json DECISIONS_DIR [--reviewer "Milai Walker"] [--date 2026-10-11]

DECISIONS_DIR holds one JSON file per excerpt id (as exported from the page's `decisions`
collection). Rules (honesty contract, CLAUDE.md):
  excerpt "approve" → listingStatus "published";  "hold" → "in_review".
  prose "approve" → reviewStatus "approved" (+ reviewedBy/At);  "edit" → text replaced,
      origin "curated", reviewStatus "approved";  "reject" → block removed.
  difficulty {value} → value set, reviewStatus "approved" (origin "curated" if changed).
  factNotes → NOT applied automatically; printed so a human turns them into sourced facts.
"""
import argparse
import datetime
import json
import pathlib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalogue")
    ap.add_argument("decisions_dir")
    ap.add_argument("--reviewer", default="Milai Walker")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    args = ap.parse_args()

    path = pathlib.Path(args.catalogue)
    data = json.loads(path.read_text())
    decisions = {}
    for f in pathlib.Path(args.decisions_dir).glob("*.json"):
        body = json.loads(f.read_text())
        decisions[f.stem] = body.get("data", body)  # accept raw bodies or {data: ...} exports

    notes = []
    changed = 0
    for ex in data["excerpts"]:
        d = decisions.get(ex["id"])
        if not d:
            continue
        verdict = d.get("excerpt")
        if verdict == "approve":
            ex["listingStatus"] = "published"
        elif verdict == "hold":
            ex["listingStatus"] = "in_review"
        prose = ex.get("prose") or {}
        for key, pd in (d.get("prose") or {}).items():
            block = prose.get(key)
            if not block:
                continue
            status = pd.get("status")
            if status == "approve":
                block.update(reviewStatus="approved", reviewedBy=args.reviewer, reviewedAt=args.date)
            elif status == "edit" and pd.get("text", "").strip():
                block.update(text=pd["text"].strip(), origin="curated", reviewStatus="approved",
                             reviewedBy=args.reviewer, reviewedAt=args.date)
            elif status == "reject":
                del prose[key]
        if prose:
            ex["prose"] = prose
        elif "prose" in ex:
            del ex["prose"]
        diff = d.get("difficulty")
        if isinstance(diff, dict) and isinstance(diff.get("value"), int) and 1 <= diff["value"] <= 5:
            old = ex.get("difficulty") or {}
            ex["difficulty"] = {
                "value": diff["value"],
                "origin": "curated" if old.get("value") != diff["value"] else old.get("origin", "curated"),
                "reviewStatus": "approved",
            }
        if (d.get("factNotes") or "").strip():
            notes.append((ex["id"], d["factNotes"].strip()))
        changed += 1

    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"applied decisions to {changed} excerpts in {path.name}")
    for eid, note in notes:
        print(f"\n[fact notes] {eid}:\n{note}")


if __name__ == "__main__":
    main()
