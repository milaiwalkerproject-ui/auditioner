"""A polite HTTP fetcher — the only code in the crawler that talks to orchestras.

Rules (docs/BOT.md), all enforced here:
* identifies itself as AuditionerBot with a link to the policy page
* robots.txt is read first and obeyed (Disallow, Crawl-delay)
* one request at a time per host, at least 10 s apart (more if robots.txt says so)
* conditional GET (If-None-Match / If-Modified-Since) so unchanged pages cost a 304
* backs off on 429/503 (Retry-After), stops for the run on 403
* never logs in, never sends cookies, never solves CAPTCHAs, never runs scripts
* at most 15 MB per document, http(s) only, only hosts HostPolicy allows
* redirects are followed by hand, so each hop is checked against the same rules
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import urljoin, urlsplit

import httpx

from . import USER_AGENT
from .policy import Decision, HostPolicy
from .robots import RobotsCache
from .state import SourceRecord, SourceStateStore

log = logging.getLogger("auditioner.crawler.fetch")

MAX_REDIRECTS = 5
ROBOTS_MAX_BYTES = 512 * 1024
DEFAULT_BACKOFF_SECONDS = 3600.0
ACCEPT = "text/html,application/xhtml+xml,application/pdf,application/msword," \
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document,*/*;q=0.5"


@dataclass
class FetchResult:
    url: str
    final_url: str
    status: int | None = None
    body: bytes = b""
    headers: dict[str, str] = field(default_factory=dict)
    unchanged: bool = False  # 304 or identical validator
    error: str | None = None
    skipped: bool = False  # refused before any request was made
    truncated: bool = False

    @property
    def ok(self) -> bool:
        return self.error is None and self.status is not None and 200 <= self.status < 300

    @property
    def content_type(self) -> str:
        return self.headers.get("content-type", "").split(";")[0].strip().lower()

    @property
    def etag(self) -> str | None:
        return self.headers.get("etag")

    @property
    def last_modified(self) -> str | None:
        return self.headers.get("last-modified")


@dataclass
class HostState:
    next_allowed_at: float = 0.0
    gap: float = 10.0
    blocked_until: float | None = None
    forbidden: bool = False
    failures: int = 0


class PoliteFetcher:
    def __init__(
        self,
        *,
        policy: HostPolicy,
        state: SourceStateStore,
        user_agent: str = USER_AGENT,
        min_gap_seconds: float = 10.0,
        max_bytes: int = 15 * 1024 * 1024,
        timeout_seconds: float = 30.0,
        max_retry_after_sleep: float = 120.0,
        transport: httpx.BaseTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.policy = policy
        self.state = state
        self.user_agent = user_agent
        self.min_gap = max(10.0, float(min_gap_seconds))
        self.max_bytes = int(max_bytes)
        self.max_retry_after_sleep = float(max_retry_after_sleep)
        self._clock = clock
        self._sleep = sleep
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()
        self._hosts: dict[str, HostState] = {}
        self._client = httpx.Client(
            transport=transport,
            timeout=httpx.Timeout(timeout_seconds),
            follow_redirects=False,
            headers={"User-Agent": user_agent, "Accept": ACCEPT, "Accept-Language": "en, de;q=0.8, *;q=0.5"},
        )
        self.robots = RobotsCache(self._fetch_robots_text)
        self.requests_made = 0

    # ------------------------------------------------------------------ helpers

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "PoliteFetcher":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    @staticmethod
    def _host_key(url: str) -> str:
        parts = urlsplit(url)
        return (parts.hostname or "").lower()

    def _host(self, url: str) -> HostState:
        key = self._host_key(url)
        with self._lock:
            state = self._hosts.get(key)
            if state is None:
                state = HostState(gap=self.min_gap)
                self._hosts[key] = state
            return state

    def host_state(self, url: str) -> HostState:
        return self._host(url)

    def _take_turn(self, url: str) -> None:
        """Reserve the next slot for this host, then sleep until it arrives."""
        state = self._host(url)
        with self._lock:
            now = self._clock()
            start = max(now, state.next_allowed_at)
            wait = start - now
            state.next_allowed_at = start + state.gap
        if wait > 0:
            self._sleep(wait)

    def _strip_cookies(self) -> None:
        # Never send cookies: forget anything a server set, before the next request.
        try:
            self._client.cookies.clear()
        except Exception:  # pragma: no cover - defensive
            pass

    def _fetch_robots_text(self, robots_url: str) -> tuple[int, str] | None:
        self._take_turn(robots_url)
        try:
            with self._client.stream("GET", robots_url) as response:
                self.requests_made += 1
                status = response.status_code
                if 300 <= status < 400:
                    # One redirect hop for robots.txt, on the same host only.
                    location = response.headers.get("location")
                    target = urljoin(robots_url, location) if location else None
                    if target and self._host_key(target) == self._host_key(robots_url):
                        response.close()
                        self._strip_cookies()
                        self._take_turn(target)
                        with self._client.stream("GET", target) as hop:
                            self.requests_made += 1
                            text = self._read_limited(hop, ROBOTS_MAX_BYTES).decode("utf-8", "replace")
                            self._strip_cookies()
                            return hop.status_code, text
                    return status, ""
                text = self._read_limited(response, ROBOTS_MAX_BYTES).decode("utf-8", "replace")
        except httpx.HTTPError as exc:
            log.warning("robots.txt unreachable for %s: %s", robots_url, exc.__class__.__name__)
            self._strip_cookies()
            return None
        self._strip_cookies()
        return status, text

    @staticmethod
    def _read_limited(response: httpx.Response, limit: int) -> bytes:
        chunks: list[bytes] = []
        total = 0
        for chunk in response.iter_bytes():
            total += len(chunk)
            if total > limit:
                chunks.append(chunk[: max(0, limit - (total - len(chunk)))])
                raise _TooLarge(b"".join(chunks))
            chunks.append(chunk)
        return b"".join(chunks)

    @staticmethod
    def parse_retry_after(value: str | None, now: datetime) -> float | None:
        if not value:
            return None
        value = value.strip()
        if value.isdigit():
            return float(value)
        try:
            when = parsedate_to_datetime(value)
        except (TypeError, ValueError, IndexError):
            return None
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return max(0.0, (when - now).total_seconds())

    # ------------------------------------------------------------------ public

    def fetch(
        self,
        url: str,
        *,
        linked_from: str | None = None,
        kind: str = "page",
        conditional: bool = True,
        orchestra_id: str | None = None,
    ) -> FetchResult:
        decision: Decision = self.policy.check(url, linked_from=linked_from, kind=kind)
        if not decision.allowed:
            log.info("refused %s: %s", url, decision.reason)
            return FetchResult(url=url, final_url=url, error=f"refused: {decision.reason}", skipped=True)

        host = self._host(url)
        if host.forbidden:
            return FetchResult(url=url, final_url=url, error="skipped: host answered 403 earlier this run", skipped=True)
        if host.blocked_until is not None and host.blocked_until > self._clock():
            return FetchResult(url=url, final_url=url, error="skipped: host asked us to back off", skipped=True)

        if not self.robots.can_fetch(url):
            log.info("robots.txt disallows %s", url)
            return FetchResult(url=url, final_url=url, error="robots.txt disallows this address", skipped=True)
        delay = self.robots.crawl_delay(url)
        if delay is not None and delay > host.gap:
            host.gap = min(float(delay), 300.0)

        headers: dict[str, str] = {}
        previous = self.state.get_source(url) if conditional else None
        if previous is not None:
            if previous.etag:
                headers["If-None-Match"] = previous.etag
            if previous.last_modified:
                headers["If-Modified-Since"] = previous.last_modified

        current = url
        retried_after_backoff = False
        for _hop in range(MAX_REDIRECTS + 1):
            if current != url:
                hop_decision = self.policy.check(current, linked_from=linked_from or url, kind=kind)
                if not hop_decision.allowed:
                    return FetchResult(url=url, final_url=current, error=f"redirect refused: {hop_decision.reason}")
                if not self.robots.can_fetch(current):
                    return FetchResult(url=url, final_url=current, error="redirect target disallowed by robots.txt")
            self._take_turn(current)
            try:
                with self._client.stream("GET", current, headers=headers) as response:
                    self.requests_made += 1
                    status = response.status_code
                    resp_headers = {k.lower(): v for k, v in response.headers.items()}
                    if status in (301, 302, 303, 307, 308):
                        location = resp_headers.get("location")
                        if not location:
                            return FetchResult(url=url, final_url=current, status=status, error="redirect without location")
                        current = urljoin(current, location).split("#", 1)[0]
                        headers = {}  # validators belong to the original address only
                        continue
                    if status == 304:
                        return FetchResult(url=url, final_url=current, status=304, headers=resp_headers, unchanged=True)
                    if status == 403:
                        self._host(current).forbidden = True
                        log.warning("403 from %s — not asking this host again this run", current)
                        return FetchResult(url=url, final_url=current, status=403, headers=resp_headers, error="forbidden (403)")
                    if status in (429, 503):
                        retry_after = self.parse_retry_after(resp_headers.get("retry-after"), self._now())
                        if (
                            not retried_after_backoff
                            and retry_after is not None
                            and retry_after <= self.max_retry_after_sleep
                        ):
                            retried_after_backoff = True
                            log.info("%s from %s — waiting %.0f s as asked", status, current, retry_after)
                            self._sleep(retry_after)
                            continue
                        wait = retry_after if retry_after is not None else DEFAULT_BACKOFF_SECONDS
                        host_state = self._host(current)
                        host_state.blocked_until = self._clock() + wait
                        host_state.failures += 1
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"rate limited ({status}); backing off {int(wait)} s")
                    if status >= 500:
                        self._host(current).failures += 1
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"server error ({status})")
                    if status in (404, 410):
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"gone ({status})")
                    if status >= 400:
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"client error ({status})")
                    length = resp_headers.get("content-length", "")
                    if length.isdigit() and int(length) > self.max_bytes:
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"too large ({int(length)} bytes, limit {self.max_bytes})", truncated=True)
                    try:
                        body = self._read_limited(response, self.max_bytes)
                    except _TooLarge:
                        return FetchResult(url=url, final_url=current, status=status, headers=resp_headers,
                                           error=f"too large (over {self.max_bytes} bytes)", truncated=True)
                    return FetchResult(url=url, final_url=current, status=status, body=body, headers=resp_headers)
            except httpx.TimeoutException:
                self._host(current).failures += 1
                return FetchResult(url=url, final_url=current, error="timed out")
            except httpx.HTTPError as exc:
                self._host(current).failures += 1
                return FetchResult(url=url, final_url=current, error=f"network error: {exc.__class__.__name__}")
            finally:
                self._strip_cookies()
        return FetchResult(url=url, final_url=current, error="too many redirects")

    def record(self, result: FetchResult, *, orchestra_id: str | None, kind: str,
               content_hash: str | None = None, text_hash: str | None = None, note: str | None = None) -> SourceRecord:
        """Write what we learned about this address back to the state store."""
        previous = self.state.get_source(result.url)
        now_iso = self._now().isoformat()
        record = previous or SourceRecord(url=result.url)
        record.orchestra_id = orchestra_id or record.orchestra_id
        record.kind = kind
        record.last_checked_at = now_iso
        record.note = note
        if result.unchanged:
            record.status = "unchanged"
        elif result.skipped and result.error and result.error.startswith("robots"):
            record.status = "robots"
        elif result.skipped:
            record.status = "refused"
        elif result.status == 403:
            record.status = "forbidden"
        elif result.status in (404, 410):
            record.status = "gone"
        elif result.status in (429, 503):
            record.status = "rate_limited"
        elif result.truncated:
            record.status = "too_large"
        elif result.error:
            record.status = "error"
        else:
            record.status = "ok"
            if result.etag:
                record.etag = result.etag
            if result.last_modified:
                record.last_modified = result.last_modified
            if content_hash is not None and content_hash != record.content_hash:
                record.content_hash = content_hash
                record.last_changed_at = now_iso
            if text_hash is not None:
                record.text_hash = text_hash
        self.state.put_source(record)
        return record


class _TooLarge(Exception):
    def __init__(self, partial: bytes) -> None:
        super().__init__("too large")
        self.partial = partial
