#!/usr/bin/env python3
"""Validate content/registry/orchestras.json (the crawler's list of orchestras).

Usage: python3 content/registry/validate_registry.py          (exit 1 on any problem)
Requires: pip install jsonschema

Checks: JSON Schema (schema.json), unique ids, unique Tutti org ids, https-only URLs,
no aggregator hosts anywhere (CLAUDE.md "never" list / PLAN F1), region matches country,
and the honesty rule that an entry without auditionsUrl says so in its notes.
"""
import json
import pathlib
import re
import sys
from urllib.parse import urlparse

try:
    import jsonschema
except ImportError:  # pragma: no cover
    sys.exit("pip install jsonschema")

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA = json.loads((HERE / "schema.json").read_text())
REGISTRY = HERE / "orchestras.json"

# Hosts we never read automatically (PLAN F1). A URL whose host is one of these, or a
# subdomain of one, fails validation wherever it appears (auditionsUrl, homepageUrl, source).
AGGREGATOR_HOSTS = {
    "musicalchairs.info",
    "muvac.com",
    "orchestraplan.com",
    "auditioncafe.com",
    "afm.org",
    "internationalmusician.org",
    "americanorchestras.org",
    "symphony.org",
    "facebook.com",
    "fb.com",
    "instagram.com",
    "theviolinchannel.com",
    "cellobello.org",
    "harpcolumn.com",
}

REGION_BY_COUNTRY = {
    "US": "north-america", "CA": "north-america", "PR": "north-america", "MX": "north-america",
    "GB": "uk", "IE": "europe-other",
    "DE": "europe-german", "AT": "europe-german", "CH": "europe-german",
    "NL": "europe-other", "BE": "europe-other", "FR": "europe-other", "ES": "europe-other",
    "PT": "europe-other", "IT": "europe-other", "NO": "europe-other", "SE": "europe-other",
    "DK": "europe-other", "FI": "europe-other", "PL": "europe-other", "CZ": "europe-other",
    "HU": "europe-other", "LU": "europe-other",
    "HK": "asia-pacific", "SG": "asia-pacific", "JP": "asia-pacific", "KR": "asia-pacific",
    "TW": "asia-pacific", "AU": "asia-pacific", "NZ": "asia-pacific", "MO": "asia-pacific",
}

URL_FIELDS = ("auditionsUrl", "homepageUrl", "source")
NOT_FOUND = re.compile(r"not yet found", re.I)


def is_aggregator(host: str) -> bool:
    host = host.lower()
    return any(host == h or host.endswith("." + h) for h in AGGREGATOR_HOSTS)


def check_url(label: str, url: str, problems: list[str]) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https":
        problems.append(f"{label}: must be https ({url})")
    if not parsed.netloc:
        problems.append(f"{label}: no host ({url})")
    elif is_aggregator(parsed.netloc):
        problems.append(f"{label}: aggregator host {parsed.netloc} is never crawled or linked ({url})")
    if re.search(r"\s", url):
        problems.append(f"{label}: whitespace in URL ({url})")


def extra_checks(data: dict) -> list[str]:
    problems: list[str] = []
    seen_ids: set[str] = set()
    seen_tutti: set[str] = set()
    for o in data.get("orchestras", []):
        oid = o.get("id", "<no id>")
        if oid in seen_ids:
            problems.append(f"{oid}: duplicate id")
        seen_ids.add(oid)
        tutti_id = (o.get("tutti") or {}).get("orgId")
        if tutti_id:
            if tutti_id in seen_tutti:
                problems.append(f"{oid}: duplicate tutti.orgId {tutti_id}")
            seen_tutti.add(tutti_id)
        for field in URL_FIELDS:
            if field in o:
                check_url(f"{oid}/{field}", o[field], problems)
        expected = REGION_BY_COUNTRY.get(o.get("country"))
        if expected and o.get("region") != expected:
            problems.append(f"{oid}: region {o.get('region')} does not match country {o.get('country')} (expected {expected})")
        if "auditionsUrl" not in o and not NOT_FOUND.search(o.get("notes", "")):
            problems.append(f"{oid}: no auditionsUrl, so notes must say 'audition page not yet found'")
        if "auditionsUrl" in o and "homepageUrl" in o:
            a, h = urlparse(o["auditionsUrl"]).netloc.lower(), urlparse(o["homepageUrl"]).netloc.lower()
            strip = lambda x: x[4:] if x.startswith("www.") else x  # noqa: E731
            if strip(a).split(".")[-2:] != strip(h).split(".")[-2:]:
                problems.append(f"{oid}: auditionsUrl host {a} is not on the homepage's domain {h} (is it really the orchestra's own page?)")
    return problems


def main() -> None:
    data = json.loads(REGISTRY.read_text())
    validator = jsonschema.Draft202012Validator(SCHEMA)
    errs = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
    for err in errs:
        print(f"schema: {'/'.join(map(str, err.path))}: {err.message[:300]}")
    extra = extra_checks(data)
    for p in extra:
        print(p)
    n = len(data.get("orchestras", []))
    with_url = sum(1 for o in data.get("orchestras", []) if "auditionsUrl" in o)
    print(f"{REGISTRY.name}: {n} orchestras, {with_url} with auditionsUrl, {len(errs) + len(extra)} problems")
    sys.exit(1 if errs or extra else 0)


if __name__ == "__main__":
    main()
