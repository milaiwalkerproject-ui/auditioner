"""Daily per-device scan limits, per-network request limits and the one-job-at-a-time guard.

M1: the app sends a random per-install `X-Device-Id`; this module keeps an in-memory
sliding 24-hour window per id (DAILY_SCAN_LIMIT, default 30) and lets one OMR job run
at a time with a short queue behind it. The same sliding-window counter, with an hour's
window and keyed by the client's network address (`client_ip`), slows down a flood of
POSTs to /v1/trends and /v1/account/apple from one place (HOURLY_TRENDS_POST_LIMIT,
HOURLY_SIGN_IN_LIMIT). Limits live in process memory, so they reset when the Cloud Run
instance restarts and are per instance — good enough to stop a runaway client, not a
security boundary.

M5 (PLAN.md B3): App Attest replaces/augments this — the app proves it is the genuine
Auditioner build on a real device, and signed-in users get a higher limit stored
server-side. The header-based limiter stays as a fallback for the attestation-free
path and for TestFlight builds.
"""

from __future__ import annotations

import asyncio
import ipaddress
import threading
import time
from collections import deque
from collections.abc import Callable
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

DAY_SECONDS = 24 * 60 * 60
HOUR_SECONDS = 60 * 60
MAX_DEVICE_ID_LENGTH = 128
UNKNOWN_NETWORK = "unknown"  # every request without a usable address shares this one bucket
_SWEEP_EVERY = 500  # calls between sweeps of idle devices

# One sentence for every per-network 429 (/v1/trends, /v1/account/apple). The iOS app
# shows the server's "detail" as it is on the sign-in screen.
MSG_TOO_MANY_REQUESTS = "Too many requests from this network. Try again later."


class DailyLimiter:
    """Sliding-window counter per key — a device id, an account id or a network
    address — with a day's window unless told otherwise. Thread-safe; cheap.

    `allow` and `remaining` take an optional `limit` so one counter can be read against
    different caps (a device's scans count against 30 signed out and 60 signed in)."""

    def __init__(
        self,
        limit: int,
        window_seconds: float = DAY_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.limit = max(0, int(limit))
        self.window = float(window_seconds)
        self._clock = clock
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()
        self._calls = 0

    def _cap(self, limit: int | None) -> int:
        return self.limit if limit is None else max(0, int(limit))

    def _prune(self, device_id: str, now: float) -> deque[float]:
        hits = self._hits.setdefault(device_id, deque())
        cutoff = now - self.window
        while hits and hits[0] <= cutoff:
            hits.popleft()
        return hits

    def allow(self, device_id: str, limit: int | None = None) -> bool:
        """Record one scan for the key if it is still under `limit` (the limiter's own by default)."""
        now = self._clock()
        with self._lock:
            self._calls += 1
            if self._calls % _SWEEP_EVERY == 0:
                self._sweep(now)
            hits = self._prune(device_id, now)
            if len(hits) >= self._cap(limit):
                return False
            hits.append(now)
            return True

    def refund(self, device_id: str) -> None:
        """Give back the most recent scan (the server was busy and did no work)."""
        with self._lock:
            hits = self._hits.get(device_id)
            if hits:
                hits.pop()

    def remaining(self, device_id: str, limit: int | None = None) -> int:
        now = self._clock()
        with self._lock:
            return max(0, self._cap(limit) - len(self._prune(device_id, now)))

    def _sweep(self, now: float) -> None:
        cutoff = now - self.window
        for device_id in list(self._hits):
            hits = self._hits[device_id]
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if not hits:
                del self._hits[device_id]


class Busy(Exception):
    """Too many scans are already running or waiting on this instance."""


class ConcurrencyGuard:
    """Let `max_running` OMR jobs run at once and at most `max_waiting` wait in line.

    `slot(max_wait=…)` gives up with Busy when the line does not move within
    `max_wait` seconds — the app stops waiting for a reply after 120 s, so a scan
    that cannot even start in time is better refused at once (and not charged).
    """

    def __init__(self, max_running: int = 1, max_waiting: int = 4) -> None:
        self.max_running = max(0, int(max_running))
        self.max_waiting = max(0, int(max_waiting))
        self._semaphore = asyncio.Semaphore(self.max_running)
        self.waiting = 0
        self.running = 0

    @asynccontextmanager
    async def slot(self, max_wait: float | None = None) -> AsyncIterator[None]:
        if self._semaphore.locked() and self.waiting >= self.max_waiting:
            raise Busy()
        self.waiting += 1
        try:
            if max_wait is None:
                await self._semaphore.acquire()
            else:
                try:
                    await asyncio.wait_for(self._semaphore.acquire(), timeout=max_wait)
                except asyncio.TimeoutError:
                    raise Busy() from None
        finally:
            self.waiting -= 1
        self.running += 1
        try:
            yield
        finally:
            self.running -= 1
            self._semaphore.release()


def clean_device_id(raw: str | None) -> str | None:
    """The X-Device-Id header, trimmed; None if missing, blank, or unreasonably long."""
    if raw is None:
        return None
    value = raw.strip()
    if not value or len(value) > MAX_DEVICE_ID_LENGTH or any(c.isspace() for c in value):
        return None
    return value


def client_ip(forwarded_for: str | None, peer_host: str | None) -> str:
    """The network a request came from, as a limiter key — never for a log line.

    The LAST entry of ``X-Forwarded-For`` when it is an IP address, else the connection's
    own peer, else one shared "unknown" bucket. Google's front end in front of Cloud Run
    appends the address it saw to whatever the client sent, so only the last entry is
    beyond the client's control; a client that sends its own header just adds entries to
    the left, which are ignored. (Behind an extra load balancer the last entry would be
    that balancer — stricter, never bypassable.) IPv6 addresses count by their /64, the
    block a home or phone connection usually gets, so hopping within it is not a fresh
    allowance."""
    last = (forwarded_for or "").rsplit(",", 1)[-1].strip()
    if last:
        try:
            address = ipaddress.ip_address(last)
        except ValueError:
            address = None
        if address is not None:
            if address.version == 6:
                # An IPv4 address carried as IPv6 (::ffff:203.0.113.7) is that IPv4 address,
                # not a /64 — every such address would otherwise share the one bucket ::/64.
                mapped = address.ipv4_mapped
                if mapped is not None:
                    return str(mapped)
                return str(ipaddress.ip_network((address, 64), strict=False))
            return str(address)
    peer = (peer_host or "").strip()
    return peer or UNKNOWN_NETWORK


def request_network(request: Any) -> str:
    """`client_ip` for a Starlette/FastAPI request (anything with `.headers` and `.client`)."""
    client = getattr(request, "client", None)
    return client_ip(request.headers.get("x-forwarded-for"), getattr(client, "host", None))
