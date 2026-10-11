"""Community practice trends — "Popular with cellists" (PLAN D6): /v1/trends.

    POST   /v1/trends               X-Device-Id + {"instrument", "week": "YYYY-Www", "excerptIds": [...]} → 204
    DELETE /v1/trends               X-Device-Id → 204 (everything that device shared is deleted)
    GET    /v1/trends?instrument=   → {"enough", "fromWeek", "toWeek", "trends": [{"excerptId", "tier"}]}

Sharing is opt-in in the app and off by default. What arrives is only the instrument,
catalogue excerpt ids and an ISO week; it is stored in the Supabase table
``trend_contributions`` (supabase/migrations/20261012010000_trends.sql) over PostgREST
with the service-role key (RLS on, no policies). Rules the code keeps:

- the raw device id is never stored, sent to Supabase or logged: each contributor is
  ``HMAC-SHA256(TRENDS_SALT, device id)`` (hex); the hash and the salt are never
  logged either. Changing TRENDS_SALT orphans every stored row (DELETE can no longer
  find a player's rows; the 26-week retention still removes them), so set it once;
- excerpt ids that are not in the server's catalogue for that instrument are dropped
  silently (``Catalog.excerpts``: published only, drafts too when INCLUDE_DRAFTS is on);
- one row per contributor + instrument + week, replaced on every post; a post with no
  known excerpt left removes that week's row; rows older than 26 weeks are deleted
  (at most once an hour per instance, on any /v1/trends request);
- POST is limited per network address (HOURLY_TRENDS_POST_LIMIT, default 20 per
  sliding hour, 429): device ids are minted by the app, so this is what stands between
  one client and an endless supply of "contributors" until App Attest (PLAN B3). The
  address is a counter key in memory and is never logged;
- GET counts distinct contributors over the 8 most recent ISO weeks (current one
  included). Below 20 contributors nothing is shown. Otherwise each excerpt gets a
  tier from the share of contributors who listed it — very-popular ≥ 40 %, popular
  ≥ 15 %, nothing below — and the answer carries **no counts and no shares**; within
  a tier excerpts are in id order, so not even the ranking leaks. Answers are kept
  in memory for an hour. Should the read run past the safety stop on paging
  (MAX_PAGED_ROWS), the answer is "not enough" with no excerpts, not a partial count
  and not an error.

Hiding the section for under-18s and keeping it apart from "What orchestras ask"
are the app's job (PLAN D6).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import re
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable
from datetime import date, datetime, timedelta, timezone
from typing import Any

import httpx
from fastapi import APIRouter, Request
from fastapi.exceptions import HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from .catalog import Catalog
from .feed import BadFeedParam, feed_instrument
from .limits import MSG_TOO_MANY_REQUESTS, DailyLimiter, clean_device_id, request_network

log = logging.getLogger("auditioner.trends")

TABLE = "trend_contributions"
MIN_CONTRIBUTORS = 20          # PLAN D6: shown only with at least 20 contributors
VERY_POPULAR_PERCENT = 40      # share of contributors, whole percent (integer maths, no rounding)
POPULAR_PERCENT = 15
TIER_VERY_POPULAR = "very-popular"
TIER_POPULAR = "popular"
_TIER_ORDER = {TIER_VERY_POPULAR: 0, TIER_POPULAR: 1}
WINDOW_WEEKS = 8               # the 8 most recent ISO weeks, the current one included
RETENTION_WEEKS = 26           # rows for older weeks are deleted
MAX_EXCERPT_IDS = 50           # per post
MAX_EXCERPT_ID_CHARS = 128
CACHE_SECONDS = 3600.0         # one hour per instrument
CACHE_MAX_ENTRIES = 128        # 22 instruments × (this week, last week) fits easily
PRUNE_EVERY_SECONDS = 3600.0   # retention delete at most once an hour per instance
TIMEOUT_SECONDS = 10.0
PAGE_ROWS = 1000               # Supabase's default "max rows"; longer answers are paged
MAX_PAGED_ROWS = 500_000       # a safety stop (8 weeks × contributors), never reached by real data
ON_CONFLICT = "contributor_hash,instrument,week"

MSG_TRENDS_OFF = "Sharing what you practise isn't set up on the server yet."
MSG_TRENDS_UPSTREAM = "Practice trends didn't answer. Try again in a few minutes."
MSG_NO_DEVICE = "The app didn't say which device this is (X-Device-Id). Update the app and try again."
MSG_BAD_WEEK = "The week wasn't in the expected form (year, then ISO week number, like 2026-W41)."
MSG_WRONG_WEEK = "Only this week or last week can be shared."
MSG_TOO_MANY = "Too many excerpts at once. The most is 50 for one week."

_WEEK = re.compile(r"([0-9]{4})-W([0-9]{2})")
_HASH_IN_URL = re.compile(r"(contributor_hash=eq\.)[0-9A-Za-z]+")


class _HideContributorHash(logging.Filter):
    """httpx logs every request ("HTTP Request: DELETE https://…?contributor_hash=eq.…")
    at INFO. Deletes must name the contributor in the address (PostgREST filters), so
    this filter on the ``httpx`` logger blanks the hash before any handler sees it."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str) and "contributor_hash=" in record.msg:
            record.msg = _HASH_IN_URL.sub(r"\1[hidden]", record.msg)
        if isinstance(record.args, tuple) and any("contributor_hash=" in str(arg) for arg in record.args):
            record.args = tuple(
                _HASH_IN_URL.sub(r"\1[hidden]", str(arg)) if "contributor_hash=" in str(arg) else arg
                for arg in record.args
            )
        return True


def _install_log_filter() -> None:
    httpx_log = logging.getLogger("httpx")
    if not any(isinstance(f, _HideContributorHash) for f in httpx_log.filters):
        httpx_log.addFilter(_HideContributorHash())


_install_log_filter()


class BadTrendsParam(ValueError):
    """A value the trends endpoints cannot use. The message is for the musician (400)."""


class TrendsUpstreamError(Exception):
    """Supabase gave no usable answer: unreachable, refused, or an unexpected body (502)."""


class _TooManyRows(Exception):
    """A read ran past MAX_PAGED_ROWS: the safety stop, answered as "not enough" (200)."""


# ---------------------------------------------------------------------- ISO weeks


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_week(day: date) -> str:
    """'YYYY-Www' of the ISO week `day` falls in (the ISO year, which differs from the
    calendar year around 1 January: 2021-01-01 is in 2020-W53)."""
    year, week, _ = day.isocalendar()
    return f"{year:04d}-W{week:02d}"


def week_monday(week: str) -> date | None:
    """The Monday of a 'YYYY-Www' week; None when it is not a real ISO week
    (week 00, week 54, or week 53 in a year that has only 52)."""
    match = _WEEK.fullmatch(week)
    if match is None:
        return None
    try:
        return date.fromisocalendar(int(match[1]), int(match[2]), 1)
    except ValueError:
        return None


def parse_week(raw: Any) -> str | None:
    """The week exactly as 'YYYY-Www' (ASCII digits, capital W) when it is a real ISO
    week, surrounding spaces ignored; None otherwise."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    return text if week_monday(text) is not None else None


def _monday(day: date) -> date:
    return day - timedelta(days=day.weekday())


def accepted_weeks(today: date) -> tuple[str, str]:
    """(this week, last week) — the only weeks a post may name."""
    return iso_week(today), iso_week(today - timedelta(weeks=1))


def window_weeks(today: date, count: int = WINDOW_WEEKS) -> list[str]:
    """The `count` most recent ISO weeks, oldest first, ending with this week."""
    monday = _monday(today)
    return [iso_week(monday - timedelta(weeks=back)) for back in range(count - 1, -1, -1)]


def retention_cutoff(today: date) -> str:
    """Rows for weeks before this one are deleted: the week 26 weeks before this one
    is kept (it is exactly 26 weeks old), anything older goes. 'YYYY-Www' strings are
    fixed-width, so comparing them as text (PostgREST ``lt.``) is comparing weeks."""
    return iso_week(_monday(today) - timedelta(weeks=RETENTION_WEEKS))


def check_week(raw: Any, today: date) -> str:
    """The posted week, or BadTrendsParam (malformed, or not this week / last week)."""
    week = parse_week(raw)
    if week is None:
        raise BadTrendsParam(MSG_BAD_WEEK)
    if week not in accepted_weeks(today):
        raise BadTrendsParam(MSG_WRONG_WEEK)
    return week


# ---------------------------------------------------------------------- contributors and tiers


def contributor_hash(salt: str, device_id: str) -> str:
    """HMAC-SHA256(TRENDS_SALT, device id), hex. The only form a device is stored in."""
    return hmac.new(salt.encode("utf-8"), device_id.encode("utf-8"), hashlib.sha256).hexdigest()


def known_excerpt_ids(catalog: Catalog, instrument: str) -> set[str]:
    """Excerpt ids the server catalogue lists for `instrument` (published only, drafts
    too when INCLUDE_DRAFTS is on). Empty when there is no catalogue file for it."""
    found: set[str] = set()
    for excerpt in catalog.excerpts(instrument):
        excerpt_id = excerpt.get("id")
        if isinstance(excerpt_id, str) and excerpt_id.strip():
            found.add(excerpt_id.strip())
    return found


def keep_known(raw_ids: Iterable[Any], known: set[str]) -> list[str]:
    """The posted ids that the catalogue knows, trimmed, without repeats, sorted."""
    kept: set[str] = set()
    for raw in raw_ids:
        if not isinstance(raw, str):
            continue
        excerpt_id = raw.strip()
        if excerpt_id and len(excerpt_id) <= MAX_EXCERPT_ID_CHARS and excerpt_id in known:
            kept.add(excerpt_id)
    return sorted(kept)


def tier_for(listed: int, contributors: int) -> str | None:
    """'very-popular' when at least 40 % of contributors listed the excerpt, 'popular'
    from 15 %, None below. Whole-number maths, so 8 of 20 is exactly 40 %."""
    if contributors <= 0 or listed <= 0:
        return None
    if listed * 100 >= VERY_POPULAR_PERCENT * contributors:
        return TIER_VERY_POPULAR
    if listed * 100 >= POPULAR_PERCENT * contributors:
        return TIER_POPULAR
    return None


def summarise(
    rows: Iterable[dict[str, Any]],
    *,
    known: set[str] | None,
    from_week: str,
    to_week: str,
) -> tuple[dict[str, Any], int]:
    """The GET answer from ``trend_contributions`` rows (any number of weeks per
    contributor), plus the distinct-contributor count for the server log only.

    A contributor counts once however many weeks they shared, and an excerpt counts
    once per contributor who listed it in any of those weeks. Excerpts the catalogue
    no longer lists (`known`) are left out of the answer, not out of the count."""
    by_contributor: dict[str, set[str]] = {}
    for row in rows:
        contributor = row.get("contributor_hash")
        excerpt_ids = row.get("excerpt_ids")
        if not isinstance(contributor, str) or not contributor or not isinstance(excerpt_ids, list):
            continue
        listed = by_contributor.setdefault(contributor, set())
        listed.update(e for e in excerpt_ids if isinstance(e, str) and e)
    contributors = len(by_contributor)
    enough = contributors >= MIN_CONTRIBUTORS
    trends: list[dict[str, str]] = []
    if enough:
        listed_by: dict[str, int] = {}
        for excerpt_ids in by_contributor.values():
            for excerpt_id in excerpt_ids:
                listed_by[excerpt_id] = listed_by.get(excerpt_id, 0) + 1
        for excerpt_id, listed in listed_by.items():
            if known is not None and excerpt_id not in known:
                continue
            tier = tier_for(listed, contributors)
            if tier is not None:
                trends.append({"excerptId": excerpt_id, "tier": tier})
        # Tier, then id: the order says nothing finer than the tier does.
        trends.sort(key=lambda t: (_TIER_ORDER[t["tier"]], t["excerptId"]))
    answer: dict[str, Any] = {"enough": enough, "fromWeek": from_week, "toWeek": to_week, "trends": trends}
    return answer, contributors


# ---------------------------------------------------------------------- service


class TrendsService:
    """Writes and reads ``trend_contributions`` over PostgREST; keeps GET answers an hour.

    Off (503) unless SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and TRENDS_SALT are all
    set. `transport` lets the tests plug in an ``httpx.MockTransport``; `clock`
    (monotonic seconds, cache and retention timing) and `now` (UTC wall time, for the
    week) let them move time. A fresh ``httpx.AsyncClient`` is opened per call.
    """

    def __init__(
        self,
        url: str | None,
        service_key: str | None,
        salt: str | None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = TIMEOUT_SECONDS,
        cache_seconds: float = CACHE_SECONDS,
        prune_every_seconds: float = PRUNE_EVERY_SECONDS,
        clock: Callable[[], float] = time.monotonic,
        now: Callable[[], datetime] = _utc_now,
        page_rows: int = PAGE_ROWS,
        max_paged_rows: int = MAX_PAGED_ROWS,
    ) -> None:
        self.url = (url or "").strip().rstrip("/")
        self._key = (service_key or "").strip()
        self._salt = (salt or "").strip()
        self._transport = transport
        self.timeout = float(timeout)
        self.cache_seconds = float(cache_seconds)
        self.prune_every_seconds = float(prune_every_seconds)
        self._clock = clock
        self._now = now
        self.page_rows = max(1, int(page_rows))
        self.max_paged_rows = max(1, int(max_paged_rows))
        self._cache: OrderedDict[tuple[str, str], tuple[float, dict[str, Any]]] = OrderedDict()
        self._last_prune: float | None = None

    @property
    def configured(self) -> bool:
        return bool(self.url and self._key and self._salt)

    @property
    def endpoint(self) -> str:
        return f"{self.url}/rest/v1/{TABLE}"

    def __repr__(self) -> str:  # never show the key or the salt
        state = "configured" if self.configured else "off"
        return f"TrendsService({state}, url={self.url!r})"

    def _utc_moment(self) -> datetime:
        moment = self._now()
        return moment.astimezone(timezone.utc) if moment.tzinfo is not None else moment

    def today(self) -> date:
        """Today's date in UTC (the week a post may name is reckoned in UTC)."""
        return self._utc_moment().date()

    def contributor(self, device_id: str) -> str:
        return contributor_hash(self._salt, device_id)

    # ---- cache

    def _cached(self, key: tuple[str, str]) -> dict[str, Any] | None:
        entry = self._cache.get(key)
        if entry is None:
            return None
        expires_at, value = entry
        if self._clock() >= expires_at:
            del self._cache[key]
            return None
        return value

    def _remember(self, key: tuple[str, str], value: dict[str, Any]) -> None:
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

    async def _send(
        self,
        client: httpx.AsyncClient,
        method: str,
        what: str,
        *,
        params: dict[str, str],
        body: dict[str, Any] | None = None,
        prefer: str | None = None,
    ) -> httpx.Response:
        headers = {"Prefer": prefer} if prefer else {}
        try:
            response = await client.request(method, self.endpoint, params=params, json=body, headers=headers)
        except (httpx.HTTPError, httpx.InvalidURL) as exc:
            # Only the class: the address carries the contributor hash on deletes.
            log.warning("trends: Supabase unreachable for %s: %s", what, type(exc).__name__)
            raise TrendsUpstreamError(f"{what}: {type(exc).__name__}") from None
        if response.status_code >= 300:
            # PostgREST error bodies can quote the offending value; only the status is logged.
            log.warning("trends: Supabase answered %s for %s", response.status_code, what)
            raise TrendsUpstreamError(f"{what}: status {response.status_code}")
        return response

    async def _rows(self, client: httpx.AsyncClient, params: dict[str, str]) -> list[dict[str, Any]]:
        """Every matching row, a page at a time (Supabase caps one answer at its max rows)."""
        rows: list[dict[str, Any]] = []
        while True:
            page_params = {**params, "limit": str(self.page_rows), "offset": str(len(rows))}
            response = await self._send(client, "GET", "read", params=page_params)
            try:
                page = response.json()
            except ValueError:
                log.warning("trends: Supabase sent something that isn't JSON")
                raise TrendsUpstreamError("read: not JSON") from None
            if not isinstance(page, list) or not all(isinstance(row, dict) for row in page):
                log.warning("trends: Supabase sent an unexpected shape")
                raise TrendsUpstreamError("read: not a list of rows")
            rows.extend(page)
            if len(page) < self.page_rows:
                return rows
            if len(rows) >= self.max_paged_rows:
                raise _TooManyRows()

    async def _prune_if_due(self, client: httpx.AsyncClient) -> None:
        """Delete rows older than 26 weeks, at most once per `prune_every_seconds`.
        A failure is logged and tried again on the next request; it never fails one."""
        now = self._clock()
        if self._last_prune is not None and now - self._last_prune < self.prune_every_seconds:
            return
        cutoff = retention_cutoff(self.today())
        try:
            await self._send(client, "DELETE", "retention", params={"week": f"lt.{cutoff}"}, prefer="return=minimal")
        except TrendsUpstreamError:
            return
        self._last_prune = now
        log.info("trends: deleted contributions from weeks before %s", cutoff)

    # ---- answers

    async def share(self, device_id: str, instrument: str, week: str, excerpt_ids: list[str]) -> None:
        """Replace this contributor's row for `instrument` + `week` with `excerpt_ids`
        (already checked against the catalogue); no ids → that row is deleted."""
        if not self.configured:
            raise TrendsUpstreamError("not configured")
        contributor = self.contributor(device_id)
        async with self._client() as client:
            if excerpt_ids:
                row: dict[str, Any] = {
                    "contributor_hash": contributor,
                    "instrument": instrument,
                    "week": week,
                    "excerpt_ids": list(excerpt_ids),  # keep_known already trimmed, deduplicated and sorted them
                    "updated_at": self._utc_moment().isoformat(),
                }
                await self._send(
                    client, "POST", "share",
                    params={"on_conflict": ON_CONFLICT},
                    body=row,
                    prefer="resolution=merge-duplicates,return=minimal",
                )
            else:
                await self._send(
                    client, "DELETE", "share (nothing known)",
                    params={
                        "contributor_hash": f"eq.{contributor}",
                        "instrument": f"eq.{instrument}",
                        "week": f"eq.{week}",
                    },
                    prefer="return=minimal",
                )
            await self._prune_if_due(client)

    async def forget(self, device_id: str) -> None:
        """Delete everything this contributor shared, every instrument and week."""
        if not self.configured:
            raise TrendsUpstreamError("not configured")
        contributor = self.contributor(device_id)
        async with self._client() as client:
            await self._send(
                client, "DELETE", "forget",
                params={"contributor_hash": f"eq.{contributor}"},
                prefer="return=minimal",
            )
            await self._prune_if_due(client)

    async def trends(self, instrument: str, known: set[str] | None) -> dict[str, Any]:
        """The GET answer for one instrument over the current 8-week window."""
        if not self.configured:
            raise TrendsUpstreamError("not configured")
        weeks = window_weeks(self.today())
        key = (instrument, weeks[-1])
        cached = self._cached(key)
        if cached is not None:
            return cached
        rows: list[dict[str, Any]] | None
        async with self._client() as client:
            try:
                rows = await self._rows(client, {
                    "select": "contributor_hash,excerpt_ids",
                    "instrument": f"eq.{instrument}",
                    "week": f"in.({','.join(weeks)})",
                    "order": "contributor_hash.asc,week.asc",
                })
            except _TooManyRows:
                # The safety stop, never reached by real data: a partial read would give
                # a wrong tier, so the answer is "not enough" instead (and it is kept an
                # hour like any answer, so the pages aren't read again on every GET).
                # Nothing about the rows is logged — no hashes, no excerpt ids.
                log.warning("trends instrument=%s weeks=%s..%s: over %d rows; answering 'not enough'",
                            instrument, weeks[0], weeks[-1], self.max_paged_rows)
                rows = None
            await self._prune_if_due(client)
        if rows is None:
            answer: dict[str, Any] = {"enough": False, "fromWeek": weeks[0], "toWeek": weeks[-1], "trends": []}
        else:
            answer, contributors = summarise(rows, known=known, from_week=weeks[0], to_week=weeks[-1])
            log.info("trends instrument=%s weeks=%s..%s contributors=%d enough=%s excerpts=%d",
                     instrument, weeks[0], weeks[-1], contributors, answer["enough"], len(answer["trends"]))
        self._remember(key, answer)
        return answer


# ---------------------------------------------------------------------- routes


class TrendsShare(BaseModel):
    # Plain strings with empty defaults so a missing or odd value is a 400 in plain
    # words (not FastAPI's 422); excerptIds must be a list of strings.
    instrument: str = ""
    week: str = ""
    excerptIds: list[str] = Field(default_factory=list)


router = APIRouter()


def _service(request: Request) -> TrendsService:
    service: TrendsService = request.app.state.trends
    return service


def _device(request: Request) -> str:
    device_id = clean_device_id(request.headers.get("x-device-id"))
    if device_id is None:
        raise HTTPException(400, MSG_NO_DEVICE)
    return device_id


@router.post("/v1/trends", status_code=204)
async def share_trends(body: TrendsShare, request: Request) -> Response:
    device_id = _device(request)
    service = _service(request)
    try:
        instrument = feed_instrument(body.instrument)
        week = check_week(body.week, service.today())
    except (BadFeedParam, BadTrendsParam) as exc:
        raise HTTPException(400, str(exc)) from None
    if len(body.excerptIds) > MAX_EXCERPT_IDS:
        raise HTTPException(400, MSG_TOO_MANY)
    if not service.configured:
        raise HTTPException(503, MSG_TRENDS_OFF)
    # Per network address, counted once the post is otherwise good and about to be
    # stored (a bad request or an unconfigured server costs nothing). Not refunded when
    # Supabase fails: the limit is there to bound what one place can make us do.
    network_limiter = getattr(request.app.state, "trends_network_limiter", None)
    if isinstance(network_limiter, DailyLimiter) and not network_limiter.allow(request_network(request)):
        raise HTTPException(429, MSG_TOO_MANY_REQUESTS)
    catalog: Catalog = request.app.state.catalog
    excerpt_ids = keep_known(body.excerptIds, known_excerpt_ids(catalog, instrument))
    try:
        await service.share(device_id, instrument, week, excerpt_ids)
    except TrendsUpstreamError:
        raise HTTPException(502, MSG_TRENDS_UPSTREAM) from None
    return Response(status_code=204)


@router.delete("/v1/trends", status_code=204)
async def forget_trends(request: Request) -> Response:
    device_id = _device(request)
    service = _service(request)
    if not service.configured:
        raise HTTPException(503, MSG_TRENDS_OFF)
    try:
        await service.forget(device_id)
    except TrendsUpstreamError:
        raise HTTPException(502, MSG_TRENDS_UPSTREAM) from None
    return Response(status_code=204)


@router.get("/v1/trends")
async def get_trends(request: Request, instrument: str = "") -> JSONResponse:
    try:
        instrument_id = feed_instrument(instrument)
    except BadFeedParam as exc:
        raise HTTPException(400, str(exc)) from None
    service = _service(request)
    if not service.configured:
        raise HTTPException(503, MSG_TRENDS_OFF)
    catalog: Catalog = request.app.state.catalog
    try:
        answer = await service.trends(instrument_id, known_excerpt_ids(catalog, instrument_id))
    except TrendsUpstreamError:
        raise HTTPException(502, MSG_TRENDS_UPSTREAM) from None
    return JSONResponse(content=answer, headers={"Cache-Control": f"public, max-age={int(CACHE_SECONDS)}"})
