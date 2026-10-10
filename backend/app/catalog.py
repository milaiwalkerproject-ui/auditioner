"""Read-only access to content/catalog/*.json and fuzzy matching of OCR text.

The matcher mirrors `CatalogMatcher.rank` in the iOS app (CatalogStore.swift): text is
folded (diacritics and case removed), split into alphanumeric tokens of two or more
characters, and an excerpt scores the share of its own tokens (composer, work, title,
catalogue number, movement title, part name) that appear in the OCR text — exact
matches, or a prefix match when the OCR token is five characters or longer.
"""

from __future__ import annotations

import hashlib
import json
import re
import threading
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .instruments import INSTRUMENTS

_SPLIT_RE = re.compile(r"[\W_]+", re.UNICODE)
MIN_TOKEN = 2
PREFIX_MIN = 5


def fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in decomposed if not unicodedata.combining(c)).casefold()


def tokens(text: str) -> list[str]:
    return [t for t in _SPLIT_RE.split(fold(text)) if len(t) >= MIN_TOKEN]


def haystack(excerpt: dict[str, Any]) -> set[str]:
    movement = excerpt.get("movement") or {}
    parts = [
        excerpt.get("composer", ""),
        excerpt.get("work", ""),
        excerpt.get("title", ""),
        excerpt.get("catalogueNumber") or "",
        movement.get("title") or "",
        excerpt.get("part") or "",
    ]
    return set(tokens(" ".join(str(p) for p in parts)))


def score(query_tokens: list[str], excerpt: dict[str, Any]) -> float:
    hay = haystack(excerpt)
    if not hay or not query_tokens:
        return 0.0
    hits = {
        h for h in hay
        if any(t == h or (len(t) >= PREFIX_MIN and h.startswith(t)) for t in query_tokens)
    }
    return min(1.0, len(hits) / len(hay))


def rank(ocr_text: str, pool: list[dict[str, Any]], limit: int = 5) -> list[tuple[str, float]]:
    query = tokens(ocr_text)
    if not query:
        return []
    scored = [(str(e.get("id", "")), score(query, e)) for e in pool]
    scored = [(eid, s) for eid, s in scored if s > 0 and eid]
    scored.sort(key=lambda pair: (-pair[1], pair[0]))
    return [(eid, round(s, 4)) for eid, s in scored[:limit]]


@dataclass(frozen=True)
class CatalogFile:
    instrument: str
    path: Path
    mtime_ns: int
    raw: bytes
    etag: str
    data: dict[str, Any]

    def excerpts(self, include_drafts: bool) -> list[dict[str, Any]]:
        items = self.data.get("excerpts") or []
        if include_drafts:
            return [e for e in items if isinstance(e, dict)]
        return [e for e in items if isinstance(e, dict) and e.get("listingStatus") == "published"]


class Catalog:
    """Loads `<dir>/<instrument>.json` on demand and re-reads it when it changes."""

    def __init__(self, directory: Path, include_drafts: bool = False) -> None:
        self.directory = Path(directory)
        self.include_drafts = include_drafts
        self._cache: dict[str, CatalogFile] = {}
        self._lock = threading.Lock()

    def path_for(self, instrument: str) -> Path | None:
        if instrument not in INSTRUMENTS:
            return None
        return self.directory / f"{instrument}.json"

    def file(self, instrument: str) -> CatalogFile | None:
        path = self.path_for(instrument)
        if path is None or not path.is_file():
            return None
        mtime_ns = path.stat().st_mtime_ns
        with self._lock:
            cached = self._cache.get(instrument)
            if cached is not None and cached.mtime_ns == mtime_ns:
                return cached
        raw = path.read_bytes()
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        loaded = CatalogFile(
            instrument=instrument,
            path=path,
            mtime_ns=mtime_ns,
            raw=raw,
            etag='"' + hashlib.sha256(raw).hexdigest()[:32] + '"',
            data=data,
        )
        with self._lock:
            self._cache[instrument] = loaded
        return loaded

    def excerpts(self, instrument: str) -> list[dict[str, Any]]:
        loaded = self.file(instrument)
        if loaded is None:
            return []
        return loaded.excerpts(self.include_drafts)

    def identify(self, ocr_text: str, instrument: str, limit: int = 5) -> list[tuple[str, float]]:
        return rank(ocr_text, self.excerpts(instrument), limit=limit)
