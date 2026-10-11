from __future__ import annotations

from datetime import datetime, timezone

import httpx

from crawler.fetcher import PoliteFetcher
from crawler.policy import HostPolicy
from crawler.state import MemoryStateStore, SourceRecord

from .conftest import FakeClock, RouteTable

HOST = "https://www.example-phil.org"
PAGE = f"{HOST}/auditions"


def make_fetcher(web: RouteTable, clock: FakeClock, *, state: MemoryStateStore | None = None, **kwargs) -> PoliteFetcher:
    return PoliteFetcher(
        policy=HostPolicy(["www.example-phil.org", "other.example"]),
        state=state or MemoryStateStore(),
        transport=web.transport(),
        clock=clock,
        sleep=clock.sleep,
        now=lambda: datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc),
        **kwargs,
    )


def test_identifies_itself_and_never_sends_cookies(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "User-agent: *\nAllow: /\n")
    web.html(PAGE, "<html><body><main>Auditions</main></body></html>", **{"set-cookie": "session=abc; Path=/"})
    fetcher = make_fetcher(web, clock)
    first = fetcher.fetch(PAGE)
    second = fetcher.fetch(PAGE)
    assert first.ok and second.ok
    page_requests = web.requested(PAGE)
    assert len(page_requests) == 2
    for request in page_requests:
        assert request.headers["user-agent"].startswith("AuditionerBot/0.1 (+https://github.com/")
        assert "cookie" not in request.headers
    assert "AuditionerBot" in web.requested(f"{HOST}/robots.txt")[0].headers["user-agent"]


def test_robots_is_read_first_and_disallow_blocks_without_a_request(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "User-agent: AuditionerBot\nDisallow: /auditions\n")
    web.html(PAGE, "<html/>")
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert result.skipped and "robots.txt" in (result.error or "")
    assert [str(r.url) for r in web.requests] == [f"{HOST}/robots.txt"]
    fetcher.record(result, orchestra_id="example-phil", kind="page")
    assert fetcher.state.get_source(PAGE).status == "robots"


def test_rate_limit_per_host_with_fake_clock(web: RouteTable, clock: FakeClock):
    for host in (HOST, "https://other.example"):
        web.text(f"{host}/robots.txt", "User-agent: *\nAllow: /\n")
        web.html(f"{host}/a", "<p>a</p>")
        web.html(f"{host}/b", "<p>b</p>")
    fetcher = make_fetcher(web, clock)
    fetcher.fetch(f"{HOST}/a")  # robots + page on the same host: one gap between them
    assert clock.sleeps == [10.0]
    clock.advance(3.0)
    fetcher.fetch(f"{HOST}/b")  # only 3 s passed → waits the remaining 7 s
    assert clock.sleeps == [10.0, 7.0]
    before = list(clock.sleeps)
    fetcher.fetch("https://other.example/a")  # a different host: robots then page, no cross-host wait
    assert clock.sleeps == before + [10.0]
    clock.advance(60.0)
    fetcher.fetch(f"{HOST}/a")  # long after the gap: no sleep
    assert clock.sleeps == before + [10.0]


def test_crawl_delay_longer_than_our_gap_is_respected(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "User-agent: *\nCrawl-delay: 30\n")
    web.html(f"{HOST}/a", "<p>a</p>")
    web.html(f"{HOST}/b", "<p>b</p>")
    fetcher = make_fetcher(web, clock)
    fetcher.fetch(f"{HOST}/a")
    fetcher.fetch(f"{HOST}/b")
    assert clock.sleeps[-1] == 30.0


def test_conditional_get_sends_validators_and_handles_304(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    seen_headers: list[dict[str, str]] = []

    def page(request: httpx.Request) -> httpx.Response:
        seen_headers.append(dict(request.headers))
        if request.headers.get("if-none-match") == '"v1"':
            return httpx.Response(304, headers={"etag": '"v1"'})
        return httpx.Response(200, headers={"content-type": "text/html", "etag": '"v1"', "last-modified": "Fri, 10 Oct 2026 10:00:00 GMT"}, content=b"<p>x</p>")

    web.add(PAGE, page)
    state = MemoryStateStore()
    fetcher = make_fetcher(web, clock, state=state)
    first = fetcher.fetch(PAGE)
    assert first.ok and first.etag == '"v1"'
    assert "if-none-match" not in seen_headers[0]
    fetcher.record(first, orchestra_id="example-phil", kind="page", content_hash="abc")
    record = state.get_source(PAGE)
    assert record.etag == '"v1"' and record.last_modified == "Fri, 10 Oct 2026 10:00:00 GMT" and record.status == "ok"
    assert record.last_changed_at is not None

    second = fetcher.fetch(PAGE)
    assert second.unchanged and second.status == 304 and not second.body
    assert seen_headers[1]["if-none-match"] == '"v1"'
    assert seen_headers[1]["if-modified-since"] == "Fri, 10 Oct 2026 10:00:00 GMT"
    fetcher.record(second, orchestra_id="example-phil", kind="page")
    assert state.get_source(PAGE).status == "unchanged"
    assert state.get_source(PAGE).etag == '"v1"'  # validators kept


def test_429_with_small_retry_after_waits_then_retries_once(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    attempts = {"n": 0}

    def page(request: httpx.Request) -> httpx.Response:
        attempts["n"] += 1
        if attempts["n"] == 1:
            return httpx.Response(429, headers={"retry-after": "45"})
        return httpx.Response(200, headers={"content-type": "text/html"}, content=b"<p>ok</p>")

    web.add(PAGE, page)
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert result.ok and attempts["n"] == 2
    assert 45.0 in clock.sleeps


def test_503_with_long_retry_after_blocks_the_host_for_the_run(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.add(PAGE, httpx.Response(503, headers={"retry-after": "7200"}))
    web.html(f"{HOST}/other", "<p>x</p>")
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert not result.ok and "backing off" in (result.error or "")
    assert 7200.0 not in clock.sleeps
    blocked = fetcher.fetch(f"{HOST}/other")
    assert blocked.skipped and "back off" in (blocked.error or "")
    assert not web.requested(f"{HOST}/other")
    fetcher.record(result, orchestra_id="x", kind="page")
    assert fetcher.state.get_source(PAGE).status == "rate_limited"


def test_retry_after_http_date_is_understood():
    now = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)
    assert PoliteFetcher.parse_retry_after("Sat, 10 Oct 2026 12:01:30 GMT", now) == 90.0
    assert PoliteFetcher.parse_retry_after("120", now) == 120.0
    assert PoliteFetcher.parse_retry_after("garbage", now) is None


def test_403_stops_the_host_for_the_run(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.add(PAGE, httpx.Response(403, content=b"no"))
    web.html(f"{HOST}/list.pdf", "x")
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert result.status == 403 and not result.ok
    later = fetcher.fetch(f"{HOST}/list.pdf", kind="document")
    assert later.skipped and "403" in (later.error or "")
    assert not web.requested(f"{HOST}/list.pdf")
    fetcher.record(result, orchestra_id="x", kind="page")
    assert fetcher.state.get_source(PAGE).status == "forbidden"


def test_documents_over_the_size_limit_are_refused(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.add(f"{HOST}/big.pdf", httpx.Response(200, headers={"content-type": "application/pdf", "content-length": "99999999"}, content=b"%PDF"))
    web.add(f"{HOST}/chunked.pdf", httpx.Response(200, headers={"content-type": "application/pdf"}, content=b"x" * 5000))
    fetcher = make_fetcher(web, clock, max_bytes=4096)
    declared = fetcher.fetch(f"{HOST}/big.pdf", kind="document")
    assert declared.truncated and "too large" in (declared.error or "")
    streamed = fetcher.fetch(f"{HOST}/chunked.pdf", kind="document")
    assert streamed.truncated and "too large" in (streamed.error or "")
    fetcher.record(streamed, orchestra_id="x", kind="document")
    assert fetcher.state.get_source(f"{HOST}/chunked.pdf").status == "too_large"


def test_redirect_to_a_refused_host_is_not_followed(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.add(PAGE, httpx.Response(302, headers={"location": "https://www.musicalchairs.info/jobs"}))
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert not result.ok and "redirect refused" in (result.error or "")
    assert not any("musicalchairs" in str(r.url) for r in web.requests)


def test_redirect_on_own_host_is_followed_and_validators_dropped(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.add(PAGE, httpx.Response(301, headers={"location": "/auditions-2026"}))
    web.html(f"{HOST}/auditions-2026", "<main>new</main>")
    state = MemoryStateStore()
    state.put_source(SourceRecord(url=PAGE, etag='"old"'))
    fetcher = make_fetcher(web, clock, state=state)
    result = fetcher.fetch(PAGE)
    assert result.ok and result.final_url == f"{HOST}/auditions-2026"
    assert "if-none-match" not in web.requested(f"{HOST}/auditions-2026")[0].headers


def test_refused_policy_makes_no_request(web: RouteTable, clock: FakeClock):
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch("https://www.musicalchairs.info/jobs")
    assert result.skipped and "never reads" in (result.error or "")
    assert web.requests == []


def test_network_errors_are_reported_not_raised(web: RouteTable, clock: FakeClock):
    web.text(f"{HOST}/robots.txt", "", status=404)

    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    web.add(PAGE, boom)
    fetcher = make_fetcher(web, clock)
    result = fetcher.fetch(PAGE)
    assert not result.ok and "network error" in (result.error or "")


def test_gap_can_not_be_configured_below_ten_seconds(web: RouteTable, clock: FakeClock):
    fetcher = make_fetcher(web, clock, min_gap_seconds=1.0)
    assert fetcher.min_gap == 10.0


def test_www_and_apex_hosts_share_the_per_host_gap(web: RouteTable, clock: FakeClock):
    from crawler.fetcher import PoliteFetcher
    from crawler.policy import HostPolicy
    from crawler.state import MemoryStateStore

    web.text("https://www.example-phil.org/robots.txt", "", status=404)
    web.text("https://example-phil.org/robots.txt", "", status=404)
    web.html("https://www.example-phil.org/a", "<html><body>a</body></html>")
    web.html("https://example-phil.org/b", "<html><body>b</body></html>")
    fetcher = PoliteFetcher(policy=HostPolicy(["example-phil.org"]), state=MemoryStateStore(),
                            transport=web.transport(), clock=clock, sleep=clock.sleep)
    assert fetcher.fetch("https://www.example-phil.org/a").ok
    assert fetcher.fetch("https://example-phil.org/b").ok
    # robots.txt (www), page a, robots.txt (apex), page b: every request after the first waited the full gap
    assert len(web.requests) == 4
    assert len(clock.sleeps) == 3 and all(s >= 10 for s in clock.sleeps), clock.sleeps
