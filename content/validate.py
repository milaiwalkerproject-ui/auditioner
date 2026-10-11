#!/usr/bin/env python3
"""Validate content/catalog/*.json against the catalogue schema + honesty rules.

Usage: python3 content/validate.py            (exit 1 on any problem)
Requires: pip install jsonschema
"""
import json
import pathlib
import sys

try:
    import jsonschema
except ImportError:  # pragma: no cover
    sys.exit("pip install jsonschema")

ROOT = pathlib.Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / "schema" / "catalog.schema.json").read_text())
validator = jsonschema.Draft202012Validator(SCHEMA)


def extra_checks(path, data):
    """Rules the JSON Schema cannot express (see CLAUDE.md honesty contract)."""
    problems = []
    seen = set()
    for ex in data.get("excerpts", []):
        eid = ex.get("id")
        if eid in seen:
            problems.append(f"{eid}: duplicate id")
        seen.add(eid)
        if ex.get("instrument") != data.get("instrument"):
            problems.append(f"{eid}: instrument differs from file instrument")
        tt = (ex.get("typicalTempo") or {}).get("value")
        if tt and tt["bpmMin"] > tt["bpmMax"]:
            problems.append(f"{eid}: typicalTempo bpmMin > bpmMax")
        freq = ex.get("frequency") or {}
        if freq.get("tierStatus") == "verified" and not freq.get("evidence"):
            problems.append(f"{eid}: verified frequency tier needs evidence")
        for rec in ex.get("recordings", []):
            if rec["provider"] == "youtube" and "youtubeId" not in rec:
                problems.append(f"{eid}/{rec['id']}: youtube recording needs youtubeId")
            s, e = rec.get("start", {}), rec.get("end", {})
            if s.get("status") == "verified" and e.get("status") == "verified" and e["value"] <= s["value"]:
                problems.append(f"{eid}/{rec['id']}: end <= start")
        mx = ex.get("referenceMusicXML")
        if mx and not (ROOT / "musicxml" / mx).exists():
            problems.append(f"{eid}: referenceMusicXML {mx} missing")
    return problems


def main():
    failures = 0
    files = sorted((ROOT / "catalog").glob("*.json"))
    for path in files:
        data = json.loads(path.read_text())
        errs = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
        for err in errs:
            print(f"{path.name}: {'/'.join(map(str, err.path))}: {err.message[:300]}")
        extra = extra_checks(path, data)
        for p in extra:
            print(f"{path.name}: {p}")
        failures += len(errs) + len(extra)
        print(f"{path.name}: {len(data.get('excerpts', []))} excerpts, {len(errs) + len(extra)} problems")
    if not files:
        print("no catalogue files")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
