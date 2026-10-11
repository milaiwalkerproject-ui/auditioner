"""Where results go: Supabase (via its REST/PostgREST API) or local JSON files.

Both writers also keep the per-URL crawl state (state.py) so conditional GETs work
across runs. The Supabase writer needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
from the environment; without them the CLI falls back to the dry-run writer.

Tables are defined in supabase/migrations/20261011010000_auditions.sql. Vacancies are
keyed by a natural key (orchestra, source address, position, instrument) so a nightly
run updates the same row; items are replaced when the list's snapshot changes, and the
vacancy goes back to `in_review` because its content is new.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import quote

import httpx

from .registry import Orchestra
from .state import SourceRecord
from .textnorm import normalise

log = logging.getLogger("auditioner.crawler.store")


class StoreError(Exception):
    pass


@dataclass
class VacancyRecord:
    orchestra_id: str
    position: str
    instrument: str
    chair: str
    application_deadline: str  # "" when unknown
    audition_dates: list[dict[str, Any]]
    list_completeness: str
    source_url: str
    source_kind: str
    snapshot_hash: str
    items: list[dict[str, Any]]
    extraction: dict[str, Any] = field(default_factory=dict)
    flags: list[str] = field(default_factory=list)
    orchestra_name_in_source: str = ""

    @property
    def natural_key(self) -> str:
        raw = "|".join([self.orchestra_id, self.source_url, normalise(self.position), self.instrument, normalise(self.chair)])
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]

    def to_dict(self) -> dict[str, Any]:
        return {
            "naturalKey": self.natural_key,
            "orchestraId": self.orchestra_id,
            "orchestraNameInSource": self.orchestra_name_in_source,
            "position": self.position,
            "instrument": self.instrument,
            "chair": self.chair,
            "applicationDeadline": self.application_deadline or None,
            "auditionDates": self.audition_dates,
            "listCompleteness": self.list_completeness,
            "sourceUrl": self.source_url,
            "sourceKind": self.source_kind,
            "snapshotHash": self.snapshot_hash,
            "reviewStatus": "in_review",
            "flags": list(self.flags),
            "extraction": self.extraction,
            "items": self.items,
        }


class Writer(Protocol):
    def get_source(self, url: str) -> SourceRecord | None: ...

    def put_source(self, record: SourceRecord) -> None: ...

    def write_orchestra(self, orchestra: Orchestra) -> None: ...

    def write_vacancy(self, record: VacancyRecord) -> str: ...

    def touch_source(self, source_url: str) -> None: ...

    def finish(self, summary: dict[str, Any]) -> None: ...


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------- dry run


class DryRunWriter:
    """Writes JSON files under `out_dir` and keeps crawl state in state.json there."""

    def __init__(self, out_dir: Path | str, *, now: Callable[[], str] = _utcnow) -> None:
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._now = now
        self._lock = threading.Lock()
        self._state_path = self.out_dir / "state.json"
        self._state: dict[str, dict[str, Any]] = {}
        if self._state_path.exists():
            try:
                self._state = json.loads(self._state_path.read_text(encoding="utf-8"))
            except ValueError:
                log.warning("state.json unreadable — starting fresh")
        self.written: list[Path] = []
        self.touched: list[str] = []

    def get_source(self, url: str) -> SourceRecord | None:
        data = self._state.get(url)
        return SourceRecord.from_dict(data) if data else None

    def put_source(self, record: SourceRecord) -> None:
        with self._lock:
            self._state[record.url] = record.to_dict()
            self._state_path.write_text(json.dumps(self._state, indent=2, sort_keys=True), encoding="utf-8")

    def write_orchestra(self, orchestra: Orchestra) -> None:
        folder = self.out_dir / "orchestras"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{orchestra.id}.json"
        path.write_text(json.dumps(orchestra.to_dict(), indent=2, ensure_ascii=False), encoding="utf-8")

    def write_vacancy(self, record: VacancyRecord) -> str:
        folder = self.out_dir / "vacancies" / record.orchestra_id
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{record.natural_key}.json"
        data = record.to_dict()
        data["writtenAt"] = self._now()
        data["id"] = record.natural_key
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        with self._lock:
            self.written.append(path)
        return record.natural_key

    def touch_source(self, source_url: str) -> None:
        """A dry run keeps no vacancy table; it only remembers which sources were seen unchanged."""
        with self._lock:
            self.touched.append(source_url)

    def finish(self, summary: dict[str, Any]) -> None:
        stamp = self._now().replace(":", "-")
        path = self.out_dir / "runs" / f"{stamp}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")


# --------------------------------------------------------------------- Supabase


class SupabaseWriter:
    """Talks to PostgREST with the service-role key (never shipped to the app)."""

    def __init__(
        self,
        base_url: str,
        service_role_key: str,
        *,
        transport: httpx.BaseTransport | None = None,
        timeout_seconds: float = 30.0,
        now: Callable[[], str] = _utcnow,
    ) -> None:
        if not base_url or not service_role_key:
            raise StoreError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required")
        self.base_url = base_url.rstrip("/")
        self._now = now
        self._client = httpx.Client(
            base_url=f"{self.base_url}/rest/v1",
            transport=transport,
            timeout=httpx.Timeout(timeout_seconds),
            headers={
                "apikey": service_role_key,
                "Authorization": f"Bearer {service_role_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )

    def close(self) -> None:
        self._client.close()

    # ---- low level

    def _request(self, method: str, path: str, *, params: dict[str, str] | None = None,
                 json_body: Any = None, prefer: str | None = None) -> Any:
        headers = {"Prefer": prefer} if prefer else {}
        try:
            response = self._client.request(method, path, params=params, json=json_body, headers=headers)
        except httpx.HTTPError as exc:
            raise StoreError(f"Supabase unreachable: {exc.__class__.__name__}") from exc
        if response.status_code >= 400:
            snippet = response.text[:300].replace("\n", " ")
            raise StoreError(f"Supabase {method} {path} → {response.status_code}: {snippet}")
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError:
            return None

    def _upsert(self, table: str, rows: list[dict[str, Any]], *, on_conflict: str) -> Any:
        return self._request(
            "POST", f"/{table}", params={"on_conflict": on_conflict}, json_body=rows,
            prefer="resolution=merge-duplicates,return=representation",
        )

    # ---- state

    def get_source(self, url: str) -> SourceRecord | None:
        rows = self._request("GET", "/audition_sources", params={"url": f"eq.{url}", "select": "*", "limit": "1"})
        if not rows:
            return None
        row = rows[0]
        return SourceRecord(
            url=row["url"],
            orchestra_id=row.get("orchestra_id"),
            kind=row.get("kind") or "page",
            etag=row.get("etag"),
            last_modified=row.get("last_modified"),
            content_hash=row.get("content_hash"),
            text_hash=row.get("text_hash"),
            last_checked_at=row.get("last_checked_at"),
            last_changed_at=row.get("last_changed_at"),
            status=row.get("status") or "ok",
            note=row.get("note"),
            extra=dict(row.get("extra") or {}),
        )

    def put_source(self, record: SourceRecord) -> None:
        row = {
            "url": record.url,
            "orchestra_id": record.orchestra_id,
            "kind": record.kind,
            "etag": record.etag,
            "last_modified": record.last_modified,
            "content_hash": record.content_hash,
            "text_hash": record.text_hash,
            "last_checked_at": record.last_checked_at,
            "last_changed_at": record.last_changed_at,
            "status": record.status,
            "note": record.note,
            "extra": record.extra,
        }
        self._upsert("audition_sources", [row], on_conflict="url")

    # ---- data

    def write_orchestra(self, orchestra: Orchestra) -> None:
        self._upsert("orchestras", [{"id": orchestra.id, "data": orchestra.to_dict(), "updated_at": self._now()}], on_conflict="id")

    def write_vacancy(self, record: VacancyRecord) -> str:
        now = self._now()
        key = record.natural_key
        existing = self._request(
            "GET", "/vacancies",
            params={"natural_key": f"eq.{key}", "select": "id,snapshot_hash,review_status", "limit": "1"},
        )
        if existing and existing[0].get("snapshot_hash") == record.snapshot_hash:
            vacancy_id = existing[0]["id"]
            self._request("PATCH", "/vacancies", params={"id": f"eq.{vacancy_id}"},
                          json_body={"last_seen_at": now}, prefer="return=minimal")
            return vacancy_id

        row: dict[str, Any] = {
            "natural_key": key,
            "orchestra_id": record.orchestra_id,
            "position": record.position,
            "instrument": record.instrument,
            "chair": record.chair,
            "application_deadline": record.application_deadline or None,
            "audition_dates": record.audition_dates,
            "list_completeness": record.list_completeness,
            "source_url": record.source_url,
            "source_kind": record.source_kind,
            "last_seen_at": now,
            "review_status": "in_review",
            "snapshot_hash": record.snapshot_hash,
            "extraction": record.extraction,
            "flags": record.flags,
            "updated_at": now,
        }
        if not existing:
            row["first_seen_at"] = now
        rows = self._upsert("vacancies", [row], on_conflict="natural_key")
        if not rows:
            raise StoreError("Supabase returned no vacancy row after upsert")
        vacancy_id = rows[0]["id"]
        if existing:
            self._request("DELETE", "/vacancy_items", params={"vacancy_id": f"eq.{vacancy_id}"}, prefer="return=minimal")
        items = [
            {
                "vacancy_id": vacancy_id,
                "ordinal": index,
                "raw_text": item.get("rawText") or "",
                "round": item.get("round") or "",
                "category": item.get("category") or "other",
                "composer": item.get("composer") or "",
                "work": item.get("work") or "",
                "catalogue_number": item.get("catalogueNumber") or "",
                "movement": item.get("movement") or "",
                "part": item.get("part") or "",
                "location": item.get("location") or {},
                "source_line_ids": item.get("sourceLineIds") or [],
                "notes": item.get("notes") or "",
                "excerpt_id": (item.get("mapping") or {}).get("excerptId"),
                "match_confidence": (item.get("mapping") or {}).get("confidence"),
                "match_bucket": (item.get("mapping") or {}).get("bucket") or "new_candidate",
                "verification": item.get("verification") or {},
                "review_status": "in_review",
            }
            for index, item in enumerate(record.items, start=1)
        ]
        if items:
            self._request("POST", "/vacancy_items", json_body=items, prefer="return=minimal")
        return vacancy_id

    def touch_source(self, source_url: str) -> None:
        """The page or document is still there and unchanged: every vacancy read from it is
        still listed tonight. Only `last_seen_at` moves; review status and items stay as they are."""
        self._request("PATCH", "/vacancies", params={"source_url": f"eq.{source_url}"},
                      json_body={"last_seen_at": self._now()}, prefer="return=minimal")

    def finish(self, summary: dict[str, Any]) -> None:
        self._request("POST", "/crawl_runs", json_body=[{"summary": summary, "finished_at": self._now()}], prefer="return=minimal")


def quote_param(value: str) -> str:  # exported for tests / debugging
    return quote(value, safe="")
