"""robots.txt handling, one parsed file per host for the lifetime of a run.

Fetching the robots.txt itself goes through the caller-supplied `fetch_text`, so it
obeys the same per-host gap as every other request. Interpretation follows Python's
urllib.robotparser (RFC 9309 style): 401/403 means "nothing allowed", other 4xx
means "no rules", anything else that is not a readable 2xx means we stay away for
this run — a conservative reading, by design.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from urllib import robotparser
from urllib.parse import urlsplit, urlunsplit

from . import ROBOTS_AGENT_TOKEN

# (status, text) or None when the request itself failed
RobotsFetcher = Callable[[str], "tuple[int, str] | None"]


@dataclass
class RobotsEntry:
    parser: robotparser.RobotFileParser | None
    allow_all: bool = False
    disallow_all: bool = False
    status: int | None = None


class RobotsCache:
    def __init__(self, fetch_text: RobotsFetcher, agent: str = ROBOTS_AGENT_TOKEN) -> None:
        self._fetch = fetch_text
        self._agent = agent
        self._entries: dict[str, RobotsEntry] = {}

    @staticmethod
    def robots_url(url: str) -> str:
        parts = urlsplit(url)
        return urlunsplit((parts.scheme, parts.netloc, "/robots.txt", "", ""))

    def _entry(self, url: str) -> RobotsEntry:
        parts = urlsplit(url)
        key = f"{parts.scheme}://{parts.netloc}".lower()
        entry = self._entries.get(key)
        if entry is not None:
            return entry
        result = self._fetch(self.robots_url(url))
        if result is None:
            entry = RobotsEntry(parser=None, disallow_all=True, status=None)
        else:
            status, text = result
            if status in (401, 403):
                entry = RobotsEntry(parser=None, disallow_all=True, status=status)
            elif 400 <= status < 500:
                entry = RobotsEntry(parser=None, allow_all=True, status=status)
            elif 200 <= status < 300:
                parser = robotparser.RobotFileParser()
                parser.parse(text.splitlines())
                entry = RobotsEntry(parser=parser, status=status)
            else:
                entry = RobotsEntry(parser=None, disallow_all=True, status=status)
        self._entries[key] = entry
        return entry

    def can_fetch(self, url: str) -> bool:
        entry = self._entry(url)
        if entry.allow_all:
            return True
        if entry.disallow_all or entry.parser is None:
            return False
        return entry.parser.can_fetch(self._agent, url)

    def crawl_delay(self, url: str) -> float | None:
        entry = self._entry(url)
        if entry.parser is None:
            return None
        delay = entry.parser.crawl_delay(self._agent)
        if delay is None:
            rate = entry.parser.request_rate(self._agent)
            if rate and rate.requests:
                delay = rate.seconds / rate.requests
        try:
            return float(delay) if delay is not None else None
        except (TypeError, ValueError):
            return None

    def status_for(self, url: str) -> int | None:
        return self._entry(url).status
