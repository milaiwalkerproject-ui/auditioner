"""The open-auditions feed for the app: GET /v1/auditions and GET /v1/recommendations.

Reads the Auditioner Supabase project over PostgREST (httpx) with the same
SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY as /v1/feedback; the key never leaves the
server. The service role bypasses row level security, so every query here asks for
published data itself (supabase/migrations/20261011010000_auditions.sql):

- ``open_auditions`` — a view of published vacancies only — narrowed to auditions
  that are still open (see ``open_filter``);
- ``vacancy_items`` with ``review_status=eq.published``, for those vacancies only;
- ``rpc/excerpt_recommendations`` and ``excerpt_open_now`` — both built from
  published lists only — for "What orchestras ask" and "On N open auditions now";
- ``excerpt_frequency`` (published lists only) when the app asks for every region at
  once, which the function cannot answer.

Answers are kept in memory for ten minutes per query. Nothing about the device or
the person is sent to Supabase or logged. Shapes match FeedVacancy /
FeedVacancyItem / Recommendation in ios/Auditioner/Core/Networking/APIClient.swift
(a fixed contract: every non-optional Swift field is always present with the right
JSON type, or the app throws the whole answer away).
"""

from __future__ import annotations

import logging
import math
import re
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from typing import Any

import httpx

from .instruments import INSTRUMENTS, lookup

log = logging.getLogger("auditioner.feed")

CACHE_SECONDS = 600.0          # ten minutes per query
CACHE_MAX_ENTRIES = 1024       # 22 instruments × (7 region choices) × (1 + 4 classes) fits easily
TIMEOUT_SECONDS = 10.0
MAX_VACANCIES = 500            # per answer; one instrument's open auditions are a few dozen
ITEM_CHUNK = 20                # vacancy ids per vacancy_items request (keeps the address short)
PAGE_ROWS = 1000               # Supabase's default "max rows"; longer answers are paged
MAX_PAGED_ROWS = 50_000        # a safety stop, never reached by real data
OPEN_GRACE_DAYS = 1            # a deadline that is still "today" somewhere in the world stays in
NO_DEADLINE_SEEN_DAYS = 60     # same window as the excerpt_open_now view
TIER_CORE = 0.5                # PLAN D5: Core ≥ 50 %, Common 20–50 %, Occasional below
TIER_COMMON = 0.2
TIERS = ("core", "common", "occasional")

MSG_FEED_OFF = "The auditions feed isn't set up on the server yet."
MSG_FEED_UPSTREAM = "The auditions feed didn't answer. Try again in a few minutes."

# Region ids are the registry's (content/registry/orchestras.json) and the app's
# (Features/Onboarding/ProfileOptions.swift); the phrases are for evidence lines.
REGION_PHRASES: dict[str, str] = {
    "north-america": "in North America",
    "europe-german": "in German-speaking Europe",
    "europe-other": "in other European countries",
    "uk": "in the UK",
    "asia-pacific": "in Asia-Pacific",
    "other": "in other parts of the world",
}
REGION_IDS: tuple[str, ...] = tuple(REGION_PHRASES)
ALL_REGIONS_PHRASE = "across all regions"

# The app's Position values (Core/Catalog/CatalogModels.swift) → the database's
# position classes (public.position_class: principal | assistant-principal |
# section | other). The classes are deliberately coarse; each evidence line names
# the class it counted, so a mapping never claims more than the lists show.
POSITION_IDS: tuple[str, ...] = (
    "principal", "assistant-principal", "section", "utility", "second", "high", "low", "concertmaster", "any",
)
_POSITION_CLASS: dict[str, str] = {
    "principal": "principal",
    "concertmaster": "principal",          # position_class() files concertmaster under principal
    "high": "principal",                   # high horn: "Principal Horn"; "Third Horn" lists land in "other"
    "assistant-principal": "assistant-principal",
    "section": "section",
    "utility": "section",                  # position_class() files utility under section
    "any": "section",                      # not offered in onboarding; section lists are the broadest set
    "low": "other",                        # low horn: "Second Horn", "Fourth Horn"
    "second": "other",                     # winds/brass/harp: "Second Oboe", "2nd Trumpet" (strings: see below)
}
# For section strings "Second" means the second-violin (or a string) section:
# "Section Second Violin" is classed as section.
STRING_SECTIONS = frozenset({"violin", "viola", "cello", "double-bass"})
POSITION_CLASSES: tuple[str, ...] = ("principal", "assistant-principal", "section", "other")
_CLASS_WORDS = {"principal": "principal", "assistant-principal": "assistant principal", "section": "section"}

_VACANCY_COLUMNS = ",".join([
    "id", "orchestra_id", "orchestra_name", "region", "position", "instrument", "chair",
    "application_deadline", "audition_dates", "list_completeness", "source_url", "last_seen_at",
])
_ITEM_COLUMNS = "id,vacancy_id,ordinal,raw_text,category,round,excerpt_id"
_FREQUENCY_COLUMNS = ",".join([
    "region", "excerpt_id", "weighted_hits", "weighted_lists", "n_lists_with_excerpt", "n_lists",
    "earliest_list_date", "latest_list_date",
])
_DATE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})")


class BadFeedParam(ValueError):
    """A query parameter the feed cannot use. The message is for the musician (400)."""


class FeedUpstreamError(Exception):
    """Supabase gave no usable answer: unreachable, refused, or an unexpected body (502)."""


# ---------------------------------------------------------------------- parameters


def _shown(raw: str | None) -> str:
    return (raw or "").strip()[:40] or "(blank)"


def feed_instrument(raw: str | None) -> str:
    """One of the 22 catalogue instrument ids, or BadFeedParam."""
    info = lookup(raw or "")
    if info is None:
        raise BadFeedParam(f"Unknown instrument '{_shown(raw)}'. Pick your instrument in the app and try again.")
    return info.id


def feed_region(raw: str | None) -> str | None:
    """A region id, None for "every region" (no or empty parameter), or BadFeedParam."""
    value = (raw or "").strip().lower()
    if not value:
        return None
    if value not in REGION_PHRASES:
        raise BadFeedParam(f"Unknown region '{_shown(raw)}'. Pick your region in Settings and try again.")
    return value


def feed_position(raw: str | None) -> str:
    """One of the app's Position values, or BadFeedParam."""
    value = (raw or "").strip().lower()
    if value not in _POSITION_CLASS:
        raise BadFeedParam(f"Unknown position '{_shown(raw)}'. Pick your position in Settings and try again.")
    return value


def position_class(position: str, instrument: str) -> str:
    """The database position class used for an app position on an instrument."""
    if position == "second" and instrument in STRING_SECTIONS:
        return "section"
    return _POSITION_CLASS[position]


def _utc_today() -> date:
    return datetime.now(timezone.utc).date()


def open_filter(today: date) -> str:
    """PostgREST `or` filter for "still open": a deadline from yesterday (UTC) on, so
    a deadline that is still today somewhere stays listed; or no deadline and seen on
    the orchestra's page in the last 60 days (the excerpt_open_now window)."""
    deadline_from = (today - timedelta(days=OPEN_GRACE_DAYS)).isoformat()
    seen_from = (today - timedelta(days=NO_DEADLINE_SEEN_DAYS)).isoformat()
    return f"(application_deadline.gte.{deadline_from},and(application_deadline.is.null,last_seen_at.gte.{seen_from}))"


# ---------------------------------------------------------------------- value checks


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _iso_date(value: Any, *, allow_time: bool = False) -> str | None:
    """'YYYY-MM-DD' when `value` is a real calendar date (or, with allow_time, a
    timestamp starting with one); None otherwise. Never guesses a date."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if len(text) != 10 and not (allow_time and len(text) > 10 and text[10] in "T "):
        return None
    match = _DATE.match(text)
    if match is None:
        return None
    try:
        date(int(match[1]), int(match[2]), int(match[3]))
    except ValueError:
        return None
    return text[:10]


def _year(value: Any) -> int | None:
    day = _iso_date(value)
    return int(day[:4]) if day else None


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    return result if math.isfinite(result) else None


def _count(value: Any) -> int | None:
    number = _number(value)
    if number is None or number < 0 or number != int(number):
        return None
    return int(number)


def _uuid(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value.strip()))
    except ValueError:
        return None


def _audition_dates(value: Any) -> list[str]:
    """The crawler stores [{"value": "YYYY-MM-DD", "sourceLineIds": [...]}]; a date
    typed in the table editor may be a plain string. Anything else is dropped."""
    if not isinstance(value, list):
        return []
    found: set[str] = set()
    for entry in value:
        raw = entry.get("value") if isinstance(entry, dict) else entry
        day = _iso_date(raw)
        if day:
            found.add(day)
    return sorted(found)


# ---------------------------------------------------------------------- mapping


def map_item(row: dict[str, Any]) -> dict[str, Any] | None:
    """A published vacancy_items row → FeedVacancyItem. None for a row without its
    evidence (the database refuses to publish one, so this is only a safety net)."""
    raw_text = _text(row.get("raw_text"))
    if not raw_text:
        return None
    return {
        "rawText": raw_text,
        "category": _text(row.get("category")) or "other",
        "round": _text(row.get("round")),
        "excerptId": _text(row.get("excerpt_id")) or None,
    }


def map_vacancy(row: dict[str, Any], items: list[dict[str, Any]]) -> dict[str, Any] | None:
    """An open_auditions row → FeedVacancy. None when a field the app requires is
    missing (logged; the rest of the feed still goes out)."""
    vacancy_id = _uuid(row.get("id"))
    position = _text(row.get("position"))
    instrument = _text(row.get("instrument"))
    source_url = _text(row.get("source_url"))
    orchestra_id = _text(row.get("orchestra_id"))
    orchestra = _text(row.get("orchestra_name")) or orchestra_id
    if not (vacancy_id and position and instrument and orchestra and source_url.startswith(("https://", "http://"))):
        return None
    chair = _text(row.get("chair"))
    if chair and chair.casefold() not in position.casefold():
        position = f"{position} ({chair})"
    return {
        "id": vacancy_id,
        "orchestra": orchestra,
        "orchestraId": orchestra_id or None,
        "region": _text(row.get("region")) or None,
        "position": position,
        "instrument": instrument,
        "applicationDeadline": _iso_date(row.get("application_deadline")),
        "auditionDates": _audition_dates(row.get("audition_dates")),
        "listCompleteness": _text(row.get("list_completeness")) or "unknown",
        "sourceURL": source_url,
        "lastCheckedAt": _iso_date(row.get("last_seen_at"), allow_time=True),
        "items": items,
    }


def _instrument_words(instrument: str) -> str:
    info = INSTRUMENTS.get(instrument)
    name = info.name if info else instrument.replace("-", " ")
    if name.startswith("E♭"):
        return name
    return name[:1].lower() + name[1:]


def lists_phrase(position_class_id: str, instrument: str, count: int) -> str:
    """'section cello lists', 'oboe lists for second and other chairs', …"""
    noun = "list" if count == 1 else "lists"
    words = _instrument_words(instrument)
    if position_class_id in _CLASS_WORDS:
        return f"{_CLASS_WORDS[position_class_id]} {words} {noun}"
    return f"{words} {noun} for second and other chairs"


def _years(first: int | None, last: int | None) -> str:
    if first is None and last is None:
        return ""
    if first is None or last is None or first == last:
        return str(first if first is not None else last)
    return f"{min(first, last)}–{max(first, last)}"


def evidence(
    *,
    instrument: str,
    position_class_id: str,
    region: str | None,
    listed: int,
    total: int,
    first_year: int | None = None,
    last_year: int | None = None,
) -> str:
    """The plain-words line under a recommendation, built only from the counts.

    "On 7 of 12 section cello lists in North America, 2024–2026"
    "Not on any of the 4 principal horn lists we have in the UK — the tier comes from other regions"
    "No section cello lists in Asia-Pacific yet — the tier comes from other regions"
    """
    where = REGION_PHRASES.get(region or "", ALL_REGIONS_PHRASE)
    if listed > 0:
        line = f"On {listed} of {total} {lists_phrase(position_class_id, instrument, total)} {where}"
        years = _years(first_year, last_year)
        return f"{line}, {years}" if years else line
    if total == 1:
        return (f"Not on the only {lists_phrase(position_class_id, instrument, 1)} we have {where}"
                " — the tier comes from other regions")
    if total > 1:
        return (f"Not on any of the {total} {lists_phrase(position_class_id, instrument, total)} we have {where}"
                " — the tier comes from other regions")
    return f"No {lists_phrase(position_class_id, instrument, 0)} {where} yet — the tier comes from other regions"


def tier_for(share: float) -> str:
    if share >= TIER_CORE:
        return "core"
    if share >= TIER_COMMON:
        return "common"
    return "occasional"


def _share(value: float) -> float:
    return round(min(max(value, 0.0), 1.0), 4)


def map_recommendation(
    row: dict[str, Any],
    *,
    instrument: str,
    position_class_id: str,
    region: str,
    open_now: dict[str, int],
) -> dict[str, Any] | None:
    """An excerpt_recommendations row → Recommendation. `share` is the function's
    blended `score` — the number its tier comes from — so the two always agree."""
    excerpt_id = _text(row.get("excerpt_id"))
    tier = _text(row.get("tier"))
    score = _number(row.get("score"))
    listed = _count(row.get("n_lists_with_excerpt"))
    total = _count(row.get("n_lists"))
    if not excerpt_id or tier not in TIERS or score is None or listed is None or total is None:
        return None
    return {
        "excerptId": excerpt_id,
        "tier": tier,
        "share": _share(score),
        "listCount": listed,
        "totalLists": total,
        "openNow": open_now.get(excerpt_id, 0),
        "evidence": evidence(
            instrument=instrument,
            position_class_id=position_class_id,
            region=region,
            listed=listed,
            total=total,
            first_year=_year(row.get("earliest_list_date")),
            last_year=_year(row.get("latest_list_date")),
        ),
    }


def all_region_recommendations(
    rows: list[dict[str, Any]],
    *,
    instrument: str,
    position_class_id: str,
    open_now: dict[str, int],
) -> list[dict[str, Any]]:
    """Recommendations over every region from excerpt_frequency rows (one row per
    region × excerpt, each carrying its region's list totals).

    Over all regions the function's blend changes nothing — the prior *is* the
    all-region share, and (hits + k·hits/lists) / (lists + k) = hits / lists — so
    the tier here is simply the recency-weighted share with the D5 thresholds.
    """
    region_totals: dict[str, tuple[float, int]] = {}
    excerpts: dict[str, dict[str, Any]] = {}
    for row in rows:
        excerpt_id = _text(row.get("excerpt_id"))
        hits = _number(row.get("weighted_hits"))
        lists = _number(row.get("weighted_lists"))
        listed = _count(row.get("n_lists_with_excerpt"))
        total = _count(row.get("n_lists"))
        if not excerpt_id or hits is None or lists is None or listed is None or total is None:
            continue
        region_totals[_text(row.get("region")) or "other"] = (lists, total)
        entry = excerpts.setdefault(excerpt_id, {"hits": 0.0, "listed": 0, "years": []})
        entry["hits"] += hits
        entry["listed"] += listed
        entry["years"].extend(y for y in (_year(row.get("earliest_list_date")), _year(row.get("latest_list_date"))) if y)
    weighted_lists = sum(lists for lists, _ in region_totals.values())
    total_lists = sum(total for _, total in region_totals.values())
    result: list[tuple[float, str, dict[str, Any]]] = []
    for excerpt_id, entry in excerpts.items():
        share = entry["hits"] / weighted_lists if weighted_lists > 0 else 0.0
        years: list[int] = entry["years"]
        result.append((share, excerpt_id, {
            "excerptId": excerpt_id,
            "tier": tier_for(share),
            "share": _share(share),
            "listCount": entry["listed"],
            "totalLists": total_lists,
            "openNow": open_now.get(excerpt_id, 0),
            "evidence": evidence(
                instrument=instrument,
                position_class_id=position_class_id,
                region=None,
                listed=entry["listed"],
                total=total_lists,
                first_year=min(years) if years else None,
                last_year=max(years) if years else None,
            ),
        }))
    result.sort(key=lambda r: (-r[0], r[1]))
    return [r[2] for r in result]


# ---------------------------------------------------------------------- service


class FeedService:
    """Reads the feed from Supabase (PostgREST) and keeps answers for ten minutes.

    `transport` lets the tests plug in an ``httpx.MockTransport``; `clock` and
    `today` let them move time. A fresh ``httpx.AsyncClient`` is opened per uncached
    answer (at most a few hundred every ten minutes), which keeps the service free
    of event-loop state.
    """

    def __init__(
        self,
        url: str | None,
        service_key: str | None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = TIMEOUT_SECONDS,
        cache_seconds: float = CACHE_SECONDS,
        clock: Callable[[], float] = time.monotonic,
        today: Callable[[], date] = _utc_today,
        page_rows: int = PAGE_ROWS,
        item_chunk: int = ITEM_CHUNK,
    ) -> None:
        self.url = (url or "").strip().rstrip("/")
        self._key = (service_key or "").strip()
        self._transport = transport
        self.timeout = float(timeout)
        self.cache_seconds = float(cache_seconds)
        self._clock = clock
        self._today = today
        self.page_rows = max(1, int(page_rows))
        self.item_chunk = max(1, int(item_chunk))
        self._cache: OrderedDict[tuple[str, ...], tuple[float, list[dict[str, Any]]]] = OrderedDict()

    @property
    def configured(self) -> bool:
        return bool(self.url and self._key)

    def __repr__(self) -> str:  # never show the key
        state = "configured" if self.configured else "off"
        return f"FeedService({state}, url={self.url!r})"

    # ---- cache

    def _cached(self, key: tuple[str, ...]) -> list[dict[str, Any]] | None:
        entry = self._cache.get(key)
        if entry is None:
            return None
        expires_at, value = entry
        if self._clock() >= expires_at:
            del self._cache[key]
            return None
        return value

    def _remember(self, key: tuple[str, ...], value: list[dict[str, Any]]) -> None:
        self._cache[key] = (self._clock() + self.cache_seconds, value)
        self._cache.move_to_end(key)
        while len(self._cache) > CACHE_MAX_ENTRIES:
            self._cache.popitem(last=False)

    def clear_cache(self) -> None:
        self._cache.clear()

    # ---- PostgREST

    def _client(self) -> httpx.AsyncClient:
        headers = {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
            "Accept": "application/json",
        }
        return httpx.AsyncClient(transport=self._transport, timeout=self.timeout, headers=headers)

    @staticmethod
    def _rows(response: httpx.Response, what: str) -> list[dict[str, Any]]:
        if response.status_code >= 300:
            # PostgREST error bodies can quote the query; only the status is logged.
            log.warning("feed: Supabase answered %s for %s", response.status_code, what)
            raise FeedUpstreamError(f"{what}: status {response.status_code}")
        try:
            data = response.json()
        except ValueError:
            log.warning("feed: Supabase sent something that isn't JSON for %s", what)
            raise FeedUpstreamError(f"{what}: not JSON") from None
        if not isinstance(data, list) or not all(isinstance(row, dict) for row in data):
            log.warning("feed: Supabase sent an unexpected shape for %s", what)
            raise FeedUpstreamError(f"{what}: not a list of rows")
        return data

    async def _get(self, client: httpx.AsyncClient, resource: str, params: dict[str, str]) -> list[dict[str, Any]]:
        try:
            response = await client.get(f"{self.url}/rest/v1/{resource}", params=params)
        except httpx.HTTPError as exc:
            log.warning("feed: Supabase unreachable for %s: %s", resource, type(exc).__name__)
            raise FeedUpstreamError(f"{resource}: {type(exc).__name__}") from exc
        return self._rows(response, resource)

    async def _get_all(
        self, client: httpx.AsyncClient, resource: str, params: dict[str, str], *, order: str
    ) -> list[dict[str, Any]]:
        """Every matching row, a page at a time (Supabase caps one answer at its max rows)."""
        rows: list[dict[str, Any]] = []
        while True:
            page_params = {**params, "order": order, "limit": str(self.page_rows), "offset": str(len(rows))}
            page = await self._get(client, resource, page_params)
            rows.extend(page)
            if len(page) < self.page_rows:
                return rows
            if len(rows) >= MAX_PAGED_ROWS:
                log.warning("feed: %s returned over %d rows; refusing a partial answer", resource, MAX_PAGED_ROWS)
                raise FeedUpstreamError(f"{resource}: too many rows")

    async def _rpc(self, client: httpx.AsyncClient, function: str, body: dict[str, Any]) -> list[dict[str, Any]]:
        what = f"rpc/{function}"
        try:
            response = await client.post(f"{self.url}/rest/v1/{what}", json=body)
        except httpx.HTTPError as exc:
            log.warning("feed: Supabase unreachable for %s: %s", what, type(exc).__name__)
            raise FeedUpstreamError(f"{what}: {type(exc).__name__}") from exc
        return self._rows(response, what)

    async def _open_now(self, client: httpx.AsyncClient, instrument: str) -> dict[str, int]:
        rows = await self._get_all(
            client, "excerpt_open_now",
            {"select": "excerpt_id,open_vacancies", "instrument": f"eq.{instrument}"},
            order="excerpt_id.asc",
        )
        counts: dict[str, int] = {}
        for row in rows:
            excerpt_id = _text(row.get("excerpt_id"))
            count = _count(row.get("open_vacancies"))
            if excerpt_id and count:
                counts[excerpt_id] = counts.get(excerpt_id, 0) + count
        return counts

    async def _items_by_vacancy(self, client: httpx.AsyncClient, ids: list[str]) -> dict[str, list[dict[str, Any]]]:
        found: dict[str, list[tuple[int, dict[str, Any]]]] = {vacancy_id: [] for vacancy_id in ids}
        for start in range(0, len(ids), self.item_chunk):
            chunk = ids[start:start + self.item_chunk]
            rows = await self._get_all(
                client, "vacancy_items",
                {
                    "select": _ITEM_COLUMNS,
                    "vacancy_id": f"in.({','.join(chunk)})",
                    "review_status": "eq.published",
                },
                order="vacancy_id.asc,ordinal.asc,id.asc",
            )
            for row in rows:
                vacancy_id = _uuid(row.get("vacancy_id"))
                item = map_item(row)
                if vacancy_id not in found or item is None:
                    continue
                ordinal = _number(row.get("ordinal"))
                found[vacancy_id].append((int(ordinal) if ordinal is not None else 0, item))
        return {
            vacancy_id: [item for _, item in sorted(entries, key=lambda entry: entry[0])]
            for vacancy_id, entries in found.items()
        }

    # ---- answers

    async def auditions(self, instrument: str, region: str | None) -> list[dict[str, Any]]:
        """Open, published auditions for one instrument (and region), soonest deadline first."""
        key = ("auditions", instrument, region or "")
        cached = self._cached(key)
        if cached is not None:
            return cached
        params = {
            "select": _VACANCY_COLUMNS,
            "instrument": f"eq.{instrument}",
            "or": open_filter(self._today()),
            "order": "application_deadline.asc.nullslast,orchestra_name.asc,id.asc",
            "limit": str(MAX_VACANCIES),
        }
        if region:
            params["region"] = f"eq.{region}"
        async with self._client() as client:
            rows = await self._get(client, "open_auditions", params)
            if len(rows) >= MAX_VACANCIES:
                log.warning("feed: %s open auditions for %s/%s; showing the first %d",
                            len(rows), instrument, region or "all", MAX_VACANCIES)
            ids = [vacancy_id for vacancy_id in (_uuid(row.get("id")) for row in rows) if vacancy_id]
            items = await self._items_by_vacancy(client, list(dict.fromkeys(ids)))
        result: list[dict[str, Any]] = []
        skipped = 0
        for row in rows:
            vacancy = map_vacancy(row, items.get(_uuid(row.get("id")) or "", []))
            if vacancy is None:
                skipped += 1
            else:
                result.append(vacancy)
        if skipped:
            log.warning("feed: skipped %d open_auditions rows missing a required field", skipped)
        log.info("feed auditions instrument=%s region=%s vacancies=%d", instrument, region or "all", len(result))
        self._remember(key, result)
        return result

    async def recommendations(self, instrument: str, position_class_id: str, region: str | None) -> list[dict[str, Any]]:
        """What orchestras ask, for one instrument + position class (+ region), most asked first."""
        key = ("recommendations", instrument, position_class_id, region or "")
        cached = self._cached(key)
        if cached is not None:
            return cached
        async with self._client() as client:
            if region:
                rows = await self._rpc(client, "excerpt_recommendations", {
                    "p_instrument": instrument,
                    "p_position_class": position_class_id,
                    "p_region": region,
                })
                open_now = await self._open_now(client, instrument)
                mapped = (
                    map_recommendation(row, instrument=instrument, position_class_id=position_class_id,
                                       region=region, open_now=open_now)
                    for row in rows
                )
                result = [rec for rec in mapped if rec is not None]
                if len(result) < len(rows):
                    log.warning("feed: skipped %d excerpt_recommendations rows with missing values",
                                len(rows) - len(result))
            else:
                rows = await self._get_all(
                    client, "excerpt_frequency",
                    {"select": _FREQUENCY_COLUMNS, "instrument": f"eq.{instrument}",
                     "position_class": f"eq.{position_class_id}"},
                    order="region.asc,excerpt_id.asc",
                )
                open_now = await self._open_now(client, instrument)
                result = all_region_recommendations(rows, instrument=instrument,
                                                    position_class_id=position_class_id, open_now=open_now)
        log.info("feed recommendations instrument=%s class=%s region=%s excerpts=%d",
                 instrument, position_class_id, region or "all", len(result))
        self._remember(key, result)
        return result
