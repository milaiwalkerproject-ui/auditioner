"""Per-URL crawl state: what we last saw at an address (ETag, Last-Modified, hashes).

The writer (store.py) persists these records — in the `audition_sources` table in
production, in a JSON file in dry runs. The fetcher only needs `get_source` and
`put_source`.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Protocol

STATUSES = ("ok", "unchanged", "gone", "forbidden", "rate_limited", "error", "refused", "too_large", "robots")


@dataclass
class SourceRecord:
    url: str
    orchestra_id: str | None = None
    kind: str = "page"  # page | document
    etag: str | None = None
    last_modified: str | None = None
    content_hash: str | None = None  # normalised page text, or raw document bytes
    text_hash: str | None = None  # extracted document text (documents only)
    last_checked_at: str | None = None
    last_changed_at: str | None = None
    status: str = "ok"
    note: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data.pop("extra", None)
        data.update(self.extra)
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SourceRecord:
        known = {f for f in cls.__dataclass_fields__ if f != "extra"}
        kwargs = {k: v for k, v in data.items() if k in known}
        extra = {k: v for k, v in data.items() if k not in known}
        record = cls(**kwargs)
        record.extra = extra
        return record


class SourceStateStore(Protocol):
    def get_source(self, url: str) -> SourceRecord | None: ...

    def put_source(self, record: SourceRecord) -> None: ...


class MemoryStateStore:
    """In-memory state; used in tests and as a fallback when nothing else is wired."""

    def __init__(self) -> None:
        self.records: dict[str, SourceRecord] = {}

    def get_source(self, url: str) -> SourceRecord | None:
        return self.records.get(url)

    def put_source(self, record: SourceRecord) -> None:
        self.records[record.url] = record
