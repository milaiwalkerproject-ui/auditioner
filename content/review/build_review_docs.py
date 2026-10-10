#!/usr/bin/env python3
"""Turn a catalogue file into review documents for the private "Excerpt review" page.

  python3 content/review/build_review_docs.py content/catalog/cello.json OUT_DIR

Writes OUT_DIR/<excerpt id>.json (one review document per excerpt) and prints the ids.
Only facts, sources and draft prose go into the review page — no user data.
"""
import json
import pathlib
import sys

LABELS = [
    ("location", "Bars"),
    ("tempoMarking", "Tempo marking"),
    ("composerMetronome", "Composer's metronome"),
    ("typicalTempo", "Typical tempo"),
    ("meter", "Meter"),
    ("key", "Key"),
]
PROSE_ORDER = ["technique", "pitfalls", "practiceTips", "history"]
SYMBOL = {"quarter": "♩", "half": "𝅗𝅥", "eighth": "♪", "dotted-quarter": "♩.", "dotted-half": "𝅗𝅥.", "dotted-eighth": "♪.", "whole": "𝅝", "sixteenth": "𝅘𝅥𝅯"}


def fact_value(key, v):
    if v is None:
        return None
    if key == "location":
        return v.get("text")
    if key in ("composerMetronome", "typicalTempo"):
        sym = SYMBOL.get(v.get("beatUnit"), v.get("beatUnit"))
        lo, hi = v.get("bpmMin"), v.get("bpmMax")
        return f"{sym} = {lo:g}" if lo == hi else f"{sym} = {lo:g}–{hi:g}"
    return v


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    data = json.loads(src.read_text())
    for i, ex in enumerate(data["excerpts"]):
        facts = []
        for key, label in LABELS:
            f = ex.get(key)
            if not f or f.get("status") == "not_applicable":
                continue
            facts.append({
                "label": label,
                "status": f["status"],
                "value": fact_value(key, f.get("value")) if f["status"] == "verified" else None,
                "source": f.get("source"),
            })
        for v in ex.get("variants") or []:
            facts.append({"label": "Also listed as", "status": "verified",
                          "value": f"{v['location']['text']} ({v.get('orchestra') or 'list'} {v.get('year') or ''})".strip(),
                          "source": v["source"]})
        mv = ex.get("movement") or {}
        subtitle = ex["title"]
        if mv.get("number"):
            subtitle = f"Mvt. {mv['number']}" + (f" ({mv['title']})" if mv.get("title") else "") + f" · {ex['title']}"
        doc = {
            "order": i,
            "instrument": ex["instrument"],
            "composer": ex["composer"],
            "work": ex["work"] + (f", {ex['catalogueNumber']}" if ex.get("catalogueNumber") else ""),
            "subtitle": subtitle,
            "positions": ex.get("positions", []),
            "facts": facts,
            "evidence": [{"description": e["description"], "source": e["source"]}
                         for e in (ex.get("frequency") or {}).get("evidence", [])],
            "prose": [{"key": k, "text": ex["prose"][k]["text"], "origin": ex["prose"][k]["origin"]}
                      for k in PROSE_ORDER if (ex.get("prose") or {}).get(k)],
            "difficulty": (ex.get("difficulty") or {}).get("value"),
            "recordings": [{"title": r.get("title"), "performer": r.get("performer"), "kind": r["kind"],
                            "youtubeId": r.get("youtubeId"), "url": r.get("url")}
                           for r in ex.get("recordings") or []],
            "sources": ex.get("sources", []),
        }
        (out / f"{ex['id']}.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1))
        print(ex["id"])


if __name__ == "__main__":
    main()
