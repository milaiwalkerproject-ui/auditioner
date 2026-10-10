"""Daily per-device scan limits and the one-job-at-a-time guard.

M1: the app sends a random per-install `X-Device-Id`; this module keeps an in-memory
sliding 24-hour window per id (DAILY_SCAN_LIMIT, default 30) and lets one OMR job run
at a time with a short queue behind it. Limits live in process memory, so they reset
when the Cloud Run instance restarts and are per instance — good enough to stop a
runaway client, not a security boundary.

M5 (PLAN.md B3): App Attest replaces/augments this — the app proves it is the genuine
Auditioner build on a real device, and signed-in users get a higher limit stored
server-side. The header-based limiter stays as a fallback for the attestation-free
path and for TestFlight builds.
"""

from __future__ import annotations

import asyncio
import threading
import time
from collections import deque
from collections.abc import Callable
from contextlib import asynccontextmanager
from typing import AsyncIterator

DAY_SECONDS = 24 * 60 * 60
MAX_DEVICE_ID_LENGTH = 128
_SWEEP_EVERY = 500  # calls between sweeps of idle devices


class DailyLimiter:
    """Sliding-window counter per device id. Thread-safe; cheap."""

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

    def _prune(self, device_id: str, now: float) -> deque[float]:
        hits = self._hits.setdefault(device_id, deque())
        cutoff = now - self.window
        while hits and hits[0] <= cutoff:
            hits.popleft()
        return hits

    def allow(self, device_id: str) -> bool:
        """Record one scan for the device if it is still under its limit."""
        now = self._clock()
        with self._lock:
            self._calls += 1
            if self._calls % _SWEEP_EVERY == 0:
                self._sweep(now)
            hits = self._prune(device_id, now)
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True

    def refund(self, device_id: str) -> None:
        """Give back the most recent scan (the server was busy and did no work)."""
        with self._lock:
            hits = self._hits.get(device_id)
            if hits:
                hits.pop()

    def remaining(self, device_id: str) -> int:
        now = self._clock()
        with self._lock:
            return max(0, self.limit - len(self._prune(device_id, now)))

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
