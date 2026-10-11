from __future__ import annotations

from crawler.robots import RobotsCache


def _cache(status: int, text: str = "") -> tuple[RobotsCache, list[str]]:
    fetched: list[str] = []

    def fetch(url: str) -> tuple[int, str] | None:
        fetched.append(url)
        return None if status == 0 else (status, text)

    return RobotsCache(fetch), fetched


def test_disallow_for_our_agent_is_honoured_and_fetched_once_per_host():
    cache, fetched = _cache(200, "User-agent: AuditionerBot\nDisallow: /private/\nCrawl-delay: 20\n\nUser-agent: *\nDisallow: /\n")
    assert cache.can_fetch("https://a.example/auditions")
    assert not cache.can_fetch("https://a.example/private/list.pdf")
    assert cache.crawl_delay("https://a.example/anything") == 20.0
    assert fetched == ["https://a.example/robots.txt"]


def test_wildcard_rules_apply_when_we_are_not_named():
    cache, _ = _cache(200, "User-agent: *\nDisallow: /secret\n")
    assert cache.can_fetch("https://a.example/auditions")
    assert not cache.can_fetch("https://a.example/secret/x")
    assert cache.crawl_delay("https://a.example/") is None


def test_missing_robots_means_no_rules():
    cache, _ = _cache(404)
    assert cache.can_fetch("https://a.example/anything")


def test_forbidden_robots_means_stay_away():
    cache, _ = _cache(403)
    assert not cache.can_fetch("https://a.example/anything")


def test_unreachable_robots_means_stay_away_this_run():
    cache, _ = _cache(0)
    assert not cache.can_fetch("https://a.example/anything")
    cache5, _ = _cache(503)
    assert not cache5.can_fetch("https://a.example/anything")


def test_request_rate_becomes_a_delay():
    cache, _ = _cache(200, "User-agent: AuditionerBot\nRequest-rate: 1/30\n")
    assert cache.crawl_delay("https://a.example/") == 30.0
