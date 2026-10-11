"""Loader for content/registry/orchestras.json — the list of orchestras whose own
audition pages the bot may read (PLAN F1/F2). The file shape is documented in
docs/FEED.md; this loader is deliberately forgiving about the wrapper (a bare list
or an object with an "orchestras" list) and strict about each entry's facts.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit

REGIONS = frozenset({"north-america", "europe-german", "europe-other", "uk", "asia-pacific", "other"})
TYPES = frozenset({"professional", "youth", "collegiate", "community"})
ID_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LIST_KEYS = ("orchestras", "entries", "items")


class RegistryError(Exception):
    """The registry file cannot be used at all (missing, not JSON, wrong shape)."""


@dataclass(frozen=True)
class Orchestra:
    id: str
    name: str
    country: str
    region: str
    type: str
    source: str
    as_of: str
    city: str | None = None
    auditions_url: str | None = None
    homepage_url: str | None = None
    notes: str | None = None
    tutti_org_id: str | None = None

    @property
    def start_url(self) -> str | None:
        return self.auditions_url or self.homepage_url

    @property
    def hosts(self) -> frozenset[str]:
        hosts: set[str] = set()
        for url in (self.auditions_url, self.homepage_url):
            host = host_of(url)
            if host:
                hosts.add(host)
        return frozenset(hosts)

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "id": self.id,
            "name": self.name,
            "country": self.country,
            "region": self.region,
            "type": self.type,
            "source": self.source,
            "asOf": self.as_of,
        }
        if self.city:
            data["city"] = self.city
        if self.auditions_url:
            data["auditionsUrl"] = self.auditions_url
        if self.homepage_url:
            data["homepageUrl"] = self.homepage_url
        if self.notes:
            data["notes"] = self.notes
        if self.tutti_org_id:
            data["tutti"] = {"orgId": self.tutti_org_id}
        return data


@dataclass
class Registry:
    orchestras: list[Orchestra] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    generated_at: str | None = None
    version: str | None = None

    def get(self, orchestra_id: str) -> Orchestra | None:
        for orchestra in self.orchestras:
            if orchestra.id == orchestra_id:
                return orchestra
        return None

    @property
    def hosts(self) -> frozenset[str]:
        hosts: set[str] = set()
        for orchestra in self.orchestras:
            hosts.update(orchestra.hosts)
        return frozenset(hosts)


def host_of(url: str | None) -> str | None:
    if not url:
        return None
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    host = (parts.hostname or "").lower().strip(".")
    return host or None


def _is_http_url(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parts = urlsplit(value)
    except ValueError:
        return False
    return parts.scheme in ("http", "https") and bool(parts.hostname)


def _optional_str(entry: dict[str, Any], key: str) -> str | None:
    value = entry.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def parse_entry(entry: Any, index: int) -> tuple[Orchestra | None, list[str]]:
    """Turn one raw entry into an Orchestra, or explain why it is unusable."""
    problems: list[str] = []
    label = f"entry {index}"
    if not isinstance(entry, dict):
        return None, [f"{label}: not an object"]
    raw_id = entry.get("id")
    if isinstance(raw_id, str) and raw_id:
        label = f"entry '{raw_id}'"
    if not isinstance(raw_id, str) or not ID_PATTERN.match(raw_id):
        problems.append(f"{label}: id must be lower-case kebab-case")
    for key in ("name", "country", "source", "asOf"):
        if not isinstance(entry.get(key), str) or not entry[key].strip():
            problems.append(f"{label}: missing '{key}'")
    region = entry.get("region")
    if region not in REGIONS:
        problems.append(f"{label}: region must be one of {sorted(REGIONS)}")
    kind = entry.get("type")
    if kind not in TYPES:
        problems.append(f"{label}: type must be one of {sorted(TYPES)}")
    as_of = entry.get("asOf")
    if isinstance(as_of, str) and not DATE_PATTERN.match(as_of):
        problems.append(f"{label}: asOf must look like 2026-10-10")
    for key in ("auditionsUrl", "homepageUrl"):
        if entry.get(key) not in (None, "") and not _is_http_url(entry.get(key)):
            problems.append(f"{label}: {key} must be an http(s) address")
    if isinstance(entry.get("source"), str) and entry["source"].strip() and not _is_http_url(entry["source"]):
        problems.append(f"{label}: source must be an http(s) address")
    tutti = entry.get("tutti")
    tutti_org_id: str | None = None
    if tutti is not None:
        if isinstance(tutti, dict) and isinstance(tutti.get("orgId"), str) and tutti["orgId"].strip():
            tutti_org_id = tutti["orgId"].strip()
        else:
            problems.append(f"{label}: tutti must be an object with 'orgId'")
    if problems:
        return None, problems
    orchestra = Orchestra(
        id=raw_id,
        name=entry["name"].strip(),
        country=entry["country"].strip(),
        region=region,
        type=kind,
        source=entry["source"].strip(),
        as_of=as_of,
        city=_optional_str(entry, "city"),
        auditions_url=_optional_str(entry, "auditionsUrl"),
        homepage_url=_optional_str(entry, "homepageUrl"),
        notes=_optional_str(entry, "notes"),
        tutti_org_id=tutti_org_id,
    )
    return orchestra, []


def parse_registry(data: Any, *, strict: bool = False) -> Registry:
    entries: Any
    registry = Registry()
    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        entries = None
        for key in LIST_KEYS:
            if isinstance(data.get(key), list):
                entries = data[key]
                break
        if entries is None:
            raise RegistryError("registry object has no 'orchestras' list")
        if isinstance(data.get("generatedAt"), str):
            registry.generated_at = data["generatedAt"]
        if isinstance(data.get("version"), str):
            registry.version = data["version"]
    else:
        raise RegistryError("registry must be a JSON list or an object with an 'orchestras' list")

    seen: set[str] = set()
    for index, raw in enumerate(entries):
        orchestra, problems = parse_entry(raw, index)
        if orchestra is None:
            registry.problems.extend(problems)
            continue
        if orchestra.id in seen:
            registry.problems.append(f"entry '{orchestra.id}': duplicate id")
            continue
        seen.add(orchestra.id)
        if orchestra.start_url is None:
            registry.problems.append(f"entry '{orchestra.id}': no auditionsUrl or homepageUrl — nothing to read")
        registry.orchestras.append(orchestra)
    if strict and registry.problems:
        raise RegistryError("; ".join(registry.problems))
    return registry


def load_registry(path: Path | str, *, strict: bool = False) -> Registry:
    path = Path(path)
    if not path.exists():
        raise RegistryError(f"registry file not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RegistryError(f"registry file unreadable: {exc}") from exc
    return parse_registry(data, strict=strict)


def select(registry: Registry, *, orchestra_id: str | None = None, limit: int | None = None) -> list[Orchestra]:
    chosen: Iterable[Orchestra] = registry.orchestras
    if orchestra_id:
        chosen = [o for o in chosen if o.id == orchestra_id]
    chosen = [o for o in chosen if o.start_url]
    if limit is not None:
        chosen = chosen[: max(0, limit)]
    return list(chosen)
