"""POST/DELETE/GET /v1/trends against a fake PostgREST table (httpx.MockTransport, no
network). Excerpt ids here are fictional fixtures; no bar numbers or other facts
appear anywhere (CLAUDE.md honesty contract)."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.limits import HOUR_SECONDS, MSG_TOO_MANY_REQUESTS, DailyLimiter
from app.main import create_app
from app.trends import (
    MIN_CONTRIBUTORS,
    MSG_BAD_WEEK,
    MSG_NO_DEVICE,
    MSG_TOO_MANY,
    MSG_TRENDS_OFF,
    MSG_TRENDS_UPSTREAM,
    MSG_WRONG_WEEK,
    TrendsService,
    accepted_weeks,
    contributor_hash,
    iso_week,
    parse_week,
    retention_cutoff,
    summarise,
    tier_for,
    week_monday,
    window_weeks,
)

SUPABASE_URL = "https://trendstest.supabase.co"
SERVICE_KEY = "service-role-key-for-trends-tests"
SALT = "trends-salt-for-tests-6c1f"
RAW_DEVICE = "RAW-DEVICE-zebra-4471"
DEVICE_HEADERS = {"X-Device-Id": RAW_DEVICE}
PATH = "/rest/v1/trend_contributions"

# Sunday 2026-10-11 (UTC) is in ISO week 2026-W41.
NOW = datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc)
THIS_WEEK = "2026-W41"
LAST_WEEK = "2026-W40"

CELLO_IDS = [f"cello-fixture-{n:02d}" for n in range(1, 61)]
CELLO_DRAFT = "cello-fixture-draft"
HORN_ID = "horn-fixture-01"


# ------------------------------------------------------------------ fakes


class FakeTable:
    """Just enough PostgREST for trend_contributions: upsert on the primary key,
    DELETE and GET with eq./in./lt. filters, select, order, limit/offset."""

    def __init__(self) -> None:
        self.rows: dict[tuple[str, str, str], dict[str, Any]] = {}
        self.requests: list[httpx.Request] = []
        self.fail_status: int | None = None
        self.fail_when: Callable[[httpx.Request], bool] | None = None
        self.raise_error: Exception | None = None

    # -- helpers

    def seed(self, contributor: str, instrument: str, week: str, excerpt_ids: list[str]) -> None:
        self.rows[(contributor, instrument, week)] = {
            "contributor_hash": contributor,
            "instrument": instrument,
            "week": week,
            "excerpt_ids": list(excerpt_ids),
            "updated_at": "2026-10-01T00:00:00+00:00",
        }

    def requests_with(self, method: str) -> list[httpx.Request]:
        return [r for r in self.requests if r.method == method]

    def retention_deletes(self) -> list[httpx.Request]:
        return [r for r in self.requests_with("DELETE") if set(r.url.params) == {"week"}]

    @staticmethod
    def _matches(row: dict[str, Any], params: httpx.QueryParams) -> bool:
        for column in ("contributor_hash", "instrument", "week"):
            if column not in params:
                continue
            condition = params[column]
            value = str(row[column])
            if condition.startswith("eq."):
                if value != condition[3:]:
                    return False
            elif condition.startswith("in.("):
                if value not in condition[4:-1].split(","):
                    return False
            elif condition.startswith("lt."):
                if not value < condition[3:]:
                    return False
            else:
                raise AssertionError(f"unexpected filter {column}={condition}")
        return True

    # -- handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_error is not None:
            raise self.raise_error
        if request.url.path != PATH:
            return httpx.Response(404, json={"message": f"unexpected {request.method} {request.url.path}"})
        if self.fail_status is not None and (self.fail_when is None or self.fail_when(request)):
            return httpx.Response(self.fail_status, content=b'{"message": "SECRET-DETAIL from PostgREST"}')
        assert request.headers["apikey"] == SERVICE_KEY
        assert request.headers["authorization"] == f"Bearer {SERVICE_KEY}"
        params = request.url.params
        if request.method == "POST":
            assert params["on_conflict"] == "contributor_hash,instrument,week"
            assert "resolution=merge-duplicates" in request.headers["prefer"]
            body = json.loads(request.content)
            assert set(body) == {"contributor_hash", "instrument", "week", "excerpt_ids", "updated_at"}
            assert 1 <= len(body["excerpt_ids"]) <= 50  # the table's CHECK constraint
            self.rows[(body["contributor_hash"], body["instrument"], body["week"])] = body
            return httpx.Response(201)
        if request.method == "DELETE":
            assert any(c in params for c in ("contributor_hash", "instrument", "week")), "unfiltered delete"
            for key in [k for k, row in self.rows.items() if self._matches(row, params)]:
                del self.rows[key]
            return httpx.Response(204)
        if request.method == "GET":
            rows = [row for row in self.rows.values() if self._matches(row, params)]
            rows.sort(key=lambda r: (r["contributor_hash"], r["week"]))
            offset = int(params.get("offset", "0"))
            limit = int(params.get("limit", str(len(rows))))
            rows = rows[offset:offset + limit]
            columns = params["select"].split(",")
            return httpx.Response(200, json=[{c: r[c] for c in columns} for r in rows])
        return httpx.Response(405)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


class WallClock:
    def __init__(self, moment: datetime = NOW) -> None:
        self.moment = moment

    def __call__(self) -> datetime:
        return self.moment


def hash_of(n: int) -> str:
    return hashlib.sha256(f"contributor-{n}".encode()).hexdigest()


def write_catalog(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    cello = [{"id": eid, "listingStatus": "published"} for eid in CELLO_IDS]
    cello.append({"id": CELLO_DRAFT, "listingStatus": "draft"})
    (directory / "cello.json").write_text(json.dumps({"instrument": "cello", "excerpts": cello}), encoding="utf-8")
    horn = [{"id": HORN_ID, "listingStatus": "published"}]
    (directory / "horn.json").write_text(json.dumps({"instrument": "horn", "excerpts": horn}), encoding="utf-8")
    return directory


@pytest.fixture
def table() -> FakeTable:
    return FakeTable()


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def wall() -> WallClock:
    return WallClock()


@pytest.fixture
def catalog_dir(tmp_path: Path) -> Path:
    return write_catalog(tmp_path / "catalog")


@pytest.fixture
def make_client(settings_factory: Callable[..., Settings], table: FakeTable, clock: Clock, wall: WallClock,
                catalog_dir: Path):
    def factory(**overrides: Any) -> TestClient:
        values: dict[str, Any] = {
            "supabase_url": SUPABASE_URL,
            "supabase_service_role_key": SERVICE_KEY,
            "trends_salt": SALT,
            "catalog_dir": catalog_dir,
        }
        values.update(overrides)
        settings = settings_factory(**values)
        app = create_app(settings)
        assert app.state.trends.configured
        app.state.trends = TrendsService(
            settings.supabase_url,
            settings.supabase_service_role_key,
            settings.trends_salt,
            transport=httpx.MockTransport(table),
            clock=clock,
            now=wall,
        )
        return TestClient(app)

    return factory


@pytest.fixture
def client(make_client) -> TestClient:
    return make_client()


def share(client: TestClient, excerpt_ids: list[Any], *, week: str = THIS_WEEK, instrument: str = "cello",
          headers: dict[str, str] | None = None) -> httpx.Response:
    body = {"instrument": instrument, "week": week, "excerptIds": excerpt_ids}
    return client.post("/v1/trends", json=body, headers=DEVICE_HEADERS if headers is None else headers)


def seed_contributors(table: FakeTable, count: int, lists: Callable[[int], list[str]], *,
                      instrument: str = "cello", week: str = THIS_WEEK, start: int = 0) -> None:
    for n in range(start, start + count):
        table.seed(hash_of(n), instrument, week, lists(n))


def numbers_in(value: Any) -> list[Any]:
    """Every int/float anywhere in a decoded JSON value (bools excluded)."""
    if isinstance(value, bool):
        return []
    if isinstance(value, (int, float)):
        return [value]
    if isinstance(value, dict):
        return [n for v in value.values() for n in numbers_in(v)]
    if isinstance(value, list):
        return [n for v in value for n in numbers_in(v)]
    return []


# ------------------------------------------------------------------ ISO week helpers


def test_iso_week_uses_the_iso_year():
    assert iso_week(date(2026, 10, 11)) == "2026-W41"
    assert iso_week(date(2021, 1, 1)) == "2020-W53"     # a Friday: still the last ISO week of 2020
    assert iso_week(date(2026, 1, 1)) == "2026-W01"     # a Thursday: the first ISO week of 2026
    assert iso_week(date(2026, 12, 31)) == "2026-W53"   # 2026 has 53 ISO weeks
    assert iso_week(date(2027, 1, 3)) == "2026-W53"
    assert iso_week(date(2027, 1, 4)) == "2027-W01"


@pytest.mark.parametrize("raw", [
    "2026-41", "2026W41", "2026-W4", "2026-W041", "26-W41", "2026-w41", "2026-W00", "2026-W54",
    "2025-W53",           # 2025 has only 52 ISO weeks
    "٢٠٢٦-W41",           # not ASCII digits
    "", "   ", "2026-W41x", "x2026-W41", "2026-W4 1", None, 202641, ["2026-W41"],
])
def test_parse_week_refuses_malformed_weeks(raw):
    assert parse_week(raw) is None


@pytest.mark.parametrize("raw,expected", [
    ("2026-W41", "2026-W41"), (" 2026-W41 ", "2026-W41"), ("2026-W53", "2026-W53"), ("2020-W53", "2020-W53"),
    ("2026-W01", "2026-W01"),
])
def test_parse_week_accepts_real_iso_weeks(raw, expected):
    assert parse_week(raw) == expected


def test_accepted_weeks_and_window_around_new_year():
    # Monday 2027-01-04 is 2027-W01; last week is 2026-W53.
    assert accepted_weeks(date(2027, 1, 4)) == ("2027-W01", "2026-W53")
    # Friday 2021-01-01 is in 2020-W53.
    assert accepted_weeks(date(2021, 1, 1)) == ("2020-W53", "2020-W52")
    # Thursday 2026-01-01 is 2026-W01; last week is 2025-W52 (2025 has no week 53).
    assert accepted_weeks(date(2026, 1, 1)) == ("2026-W01", "2025-W52")
    assert window_weeks(date(2027, 1, 6)) == [
        "2026-W47", "2026-W48", "2026-W49", "2026-W50", "2026-W51", "2026-W52", "2026-W53", "2027-W01",
    ]
    assert window_weeks(date(2026, 10, 11)) == [
        "2026-W34", "2026-W35", "2026-W36", "2026-W37", "2026-W38", "2026-W39", "2026-W40", "2026-W41",
    ]


def test_retention_cutoff_keeps_exactly_26_weeks():
    today = date(2026, 10, 11)
    cutoff = retention_cutoff(today)
    monday = date(2026, 10, 5)
    assert cutoff == iso_week(monday - timedelta(weeks=26)) == "2026-W15"
    assert iso_week(monday - timedelta(weeks=26)) >= cutoff      # 26 weeks old: kept
    assert iso_week(monday - timedelta(weeks=27)) < cutoff       # 27 weeks old: deleted
    # Across a year boundary the text order still is the week order.
    assert retention_cutoff(date(2027, 3, 1)) == "2026-W36"
    weeks = ["2026-W53", "2025-W52", "2026-W36", "2027-W01", "2026-W09", "2026-W35", "2020-W53", "2021-W01"]
    assert sorted(weeks) == sorted(weeks, key=week_monday)


# ------------------------------------------------------------------ tiers (pure)


@pytest.mark.parametrize("listed,contributors,tier", [
    (8, 20, "very-popular"),   # exactly 40 %
    (7, 20, "popular"),        # 35 %
    (3, 20, "popular"),        # exactly 15 %
    (2, 20, None),             # 10 %
    (40, 100, "very-popular"),
    (39, 100, "popular"),
    (15, 100, "popular"),
    (14, 100, None),
    (20, 20, "very-popular"),
    (0, 20, None),
    (5, 0, None),
])
def test_tier_boundaries(listed, contributors, tier):
    assert tier_for(listed, contributors) == tier


def test_summarise_counts_each_contributor_once_across_weeks():
    rows = []
    for n in range(MIN_CONTRIBUTORS):
        rows.append({"contributor_hash": hash_of(n), "excerpt_ids": ["a"]})
        rows.append({"contributor_hash": hash_of(n), "excerpt_ids": ["a", "b"] if n < 3 else ["a"]})
    answer, contributors = summarise(rows, known=None, from_week="2026-W34", to_week="2026-W41")
    assert contributors == MIN_CONTRIBUTORS
    assert answer["trends"] == [{"excerptId": "a", "tier": "very-popular"}, {"excerptId": "b", "tier": "popular"}]


def test_summarise_ignores_malformed_rows():
    rows: list[dict[str, Any]] = [{"contributor_hash": hash_of(n), "excerpt_ids": ["a"]} for n in range(19)]
    rows += [{"contributor_hash": "", "excerpt_ids": ["a"]}, {"contributor_hash": hash_of(99), "excerpt_ids": "a"},
             {"excerpt_ids": ["a"]}]
    answer, contributors = summarise(rows, known=None, from_week="x", to_week="y")
    assert contributors == 19
    assert answer["enough"] is False


# ------------------------------------------------------------------ not configured / bad input


@pytest.mark.parametrize("missing", ["supabase_url", "supabase_service_role_key", "trends_salt"])
def test_503_when_anything_is_missing(settings_factory, catalog_dir, missing):
    values = {"supabase_url": SUPABASE_URL, "supabase_service_role_key": SERVICE_KEY, "trends_salt": SALT,
              "catalog_dir": catalog_dir}
    values[missing] = ""
    app = create_app(settings_factory(**values))
    assert not app.state.trends.configured
    client = TestClient(app)
    for response in (
        share(client, [CELLO_IDS[0]]),
        client.delete("/v1/trends", headers=DEVICE_HEADERS),
        client.get("/v1/trends?instrument=cello"),
    ):
        assert response.status_code == 503
        assert response.json() == {"detail": MSG_TRENDS_OFF}


def test_salt_comes_from_the_environment_only():
    assert Settings.from_env({"TRENDS_SALT": "  abc  "}).trends_salt == "abc"
    assert Settings.from_env({}).trends_salt == ""
    assert "abc" not in repr(Settings.from_env({"TRENDS_SALT": "abc"}))
    assert SALT not in repr(TrendsService(SUPABASE_URL, SERVICE_KEY, SALT))
    assert SERVICE_KEY not in repr(TrendsService(SUPABASE_URL, SERVICE_KEY, SALT))


def test_missing_device_id_is_400(client, table):
    for headers in ({}, {"X-Device-Id": ""}, {"X-Device-Id": "has space"}, {"X-Device-Id": "x" * 200}):
        response = share(client, [CELLO_IDS[0]], headers=headers)
        assert response.status_code == 400
        assert response.json() == {"detail": MSG_NO_DEVICE}
        response = client.delete("/v1/trends", headers=headers)
        assert response.status_code == 400
        assert response.json() == {"detail": MSG_NO_DEVICE}
    assert table.requests == []


@pytest.mark.parametrize("value", ["", "kazoo", "Cello;drop", "violin,viola", "x" * 300])
def test_unknown_instrument_is_400(client, table, value):
    response = share(client, [CELLO_IDS[0]], instrument=value)
    assert response.status_code == 400
    assert response.json()["detail"].startswith("Unknown instrument")
    response = client.get("/v1/trends", params={"instrument": value})
    assert response.status_code == 400
    assert set(response.json()) == {"detail"}
    assert table.requests == []


def test_bad_parameters_are_400_even_when_not_configured(settings_factory):
    client = TestClient(create_app(settings_factory()))
    assert client.get("/v1/trends?instrument=kazoo").status_code == 400
    assert share(client, [], week="2026-W99").status_code == 400
    assert client.get("/v1/trends?instrument=cello").status_code == 503


def test_get_needs_no_device_id(client):
    assert client.get("/v1/trends?instrument=cello").status_code == 200


def test_wrong_body_types_are_422(client, table):
    response = client.post("/v1/trends", json={"instrument": "cello", "week": THIS_WEEK, "excerptIds": [1, 2]},
                           headers=DEVICE_HEADERS)
    assert response.status_code == 422
    assert set(response.json()) == {"detail"}
    response = client.post("/v1/trends", json={"instrument": "cello", "week": THIS_WEEK, "excerptIds": None},
                           headers=DEVICE_HEADERS)
    assert response.status_code == 422
    assert table.requests == []


# ------------------------------------------------------------------ week validation


def test_this_week_and_last_week_are_accepted(client, table):
    assert share(client, [CELLO_IDS[0]], week=THIS_WEEK).status_code == 204
    assert share(client, [CELLO_IDS[1]], week=LAST_WEEK).status_code == 204
    weeks = sorted(week for (_, _, week) in table.rows)
    assert weeks == [LAST_WEEK, THIS_WEEK]


@pytest.mark.parametrize("week", ["2026-W39", "2026-W42", "2025-W41", "2027-W41", "2026-W01"])
def test_other_weeks_are_refused(client, table, week):
    response = share(client, [CELLO_IDS[0]], week=week)
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_WRONG_WEEK}
    assert table.requests == []


@pytest.mark.parametrize("week", ["", "2026-41", "2026-W4", "2026-w41", "2026-W00", "2026-W54", "2025-W53", "week 41"])
def test_malformed_weeks_are_refused(client, table, week):
    response = share(client, [CELLO_IDS[0]], week=week)
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_BAD_WEEK}
    assert table.requests == []


def test_missing_week_is_400(client, table):
    response = client.post("/v1/trends", json={"instrument": "cello", "excerptIds": [CELLO_IDS[0]]},
                           headers=DEVICE_HEADERS)
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_BAD_WEEK}


def test_week_53_and_the_year_boundary(client, table, wall):
    wall.moment = datetime(2026, 12, 31, 23, 59, tzinfo=timezone.utc)   # Thursday of 2026-W53
    assert share(client, [CELLO_IDS[0]], week="2026-W53").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2026-W52").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2027-W01").status_code == 400

    wall.moment = datetime(2027, 1, 4, 0, 1, tzinfo=timezone.utc)       # Monday of 2027-W01
    assert share(client, [CELLO_IDS[0]], week="2027-W01").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2026-W53").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2026-W52").status_code == 400

    wall.moment = datetime(2021, 1, 1, 12, 0, tzinfo=timezone.utc)      # Friday, still 2020-W53
    assert share(client, [CELLO_IDS[0]], week="2020-W53").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2021-W01").status_code == 400  # next week
    response = share(client, [CELLO_IDS[0]], week="2021-W53")                # not a real week
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_BAD_WEEK}


def test_week_is_reckoned_in_utc(client, table, wall):
    # 23:30 on Sunday in New York is already Monday in UTC: the new week.
    wall.moment = datetime(2026, 10, 11, 23, 30, tzinfo=timezone(timedelta(hours=-4)))
    assert share(client, [CELLO_IDS[0]], week="2026-W42").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2026-W41").status_code == 204
    assert share(client, [CELLO_IDS[0]], week="2026-W40").status_code == 400


# ------------------------------------------------------------------ what gets stored


def test_share_stores_one_row_with_the_hashed_contributor(client, table):
    response = share(client, [CELLO_IDS[2], CELLO_IDS[0]])
    assert response.status_code == 204
    assert response.content == b""
    expected_hash = hmac.new(SALT.encode(), RAW_DEVICE.encode(), hashlib.sha256).hexdigest()
    assert expected_hash == contributor_hash(SALT, RAW_DEVICE)
    assert expected_hash != hashlib.sha256((SALT + RAW_DEVICE).encode()).hexdigest()
    assert list(table.rows) == [(expected_hash, "cello", THIS_WEEK)]
    row = table.rows[(expected_hash, "cello", THIS_WEEK)]
    assert row["excerpt_ids"] == [CELLO_IDS[0], CELLO_IDS[2]]
    assert datetime.fromisoformat(row["updated_at"]) == NOW


def test_instrument_is_normalised(client, table):
    assert share(client, [HORN_ID], instrument=" Horn ").status_code == 204
    assert [instrument for (_, instrument, _) in table.rows] == ["horn"]


def test_unknown_excerpts_are_dropped_silently(client, table):
    response = share(client, [
        CELLO_IDS[0], "not-in-the-catalogue", HORN_ID, CELLO_DRAFT, f" {CELLO_IDS[1]} ", CELLO_IDS[0], "", "   ",
        "x" * 500,
    ])
    assert response.status_code == 204
    (row,) = table.rows.values()
    assert row["excerpt_ids"] == [CELLO_IDS[0], CELLO_IDS[1]]  # horn id, draft, unknown, blanks and repeats gone


def test_drafts_count_when_include_drafts_is_on(make_client, table):
    client = make_client(include_drafts=True)
    assert share(client, [CELLO_DRAFT]).status_code == 204
    (row,) = table.rows.values()
    assert row["excerpt_ids"] == [CELLO_DRAFT]


def test_instrument_without_a_catalogue_stores_nothing(client, table):
    response = share(client, [CELLO_IDS[0], "violin-anything"], instrument="violin")
    assert response.status_code == 204
    assert table.rows == {}
    assert table.requests_with("POST") == []


def test_fifty_ids_is_the_cap(client, table):
    assert share(client, CELLO_IDS[:50]).status_code == 204
    (row,) = table.rows.values()
    assert len(row["excerpt_ids"]) == 50

    table.requests.clear()
    response = share(client, CELLO_IDS[:51])
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_TOO_MANY}
    assert table.requests == []
    (row,) = table.rows.values()
    assert row["excerpt_ids"] == sorted(CELLO_IDS[:50])  # the earlier post is untouched


def test_repost_replaces_the_week(client, table):
    assert share(client, [CELLO_IDS[0], CELLO_IDS[1]]).status_code == 204
    assert share(client, [CELLO_IDS[2]]).status_code == 204
    assert share(client, [CELLO_IDS[3]], week=LAST_WEEK).status_code == 204
    assert {week: row["excerpt_ids"] for (_, _, week), row in table.rows.items()} == {
        THIS_WEEK: [CELLO_IDS[2]],
        LAST_WEEK: [CELLO_IDS[3]],
    }


@pytest.mark.parametrize("excerpt_ids", [[], ["only-unknown-ids"]])
def test_repost_with_nothing_known_removes_that_week_only(client, table, excerpt_ids):
    assert share(client, [CELLO_IDS[0]]).status_code == 204
    assert share(client, [CELLO_IDS[1]], week=LAST_WEEK).status_code == 204
    assert share(client, [HORN_ID], instrument="horn").status_code == 204
    assert share(client, excerpt_ids).status_code == 204
    remaining = sorted((instrument, week) for (_, instrument, week) in table.rows)
    assert remaining == [("cello", LAST_WEEK), ("horn", THIS_WEEK)]


def test_delete_removes_everything_the_contributor_shared(client, table):
    table.seed(hash_of(1), "cello", THIS_WEEK, [CELLO_IDS[0]])
    table.seed(hash_of(2), "horn", LAST_WEEK, [HORN_ID])
    assert share(client, [CELLO_IDS[0]]).status_code == 204
    assert share(client, [CELLO_IDS[1]], week=LAST_WEEK).status_code == 204
    assert share(client, [HORN_ID], instrument="horn").status_code == 204
    mine = contributor_hash(SALT, RAW_DEVICE)
    assert sum(1 for (h, _, _) in table.rows if h == mine) == 3

    response = client.delete("/v1/trends", headers=DEVICE_HEADERS)
    assert response.status_code == 204
    assert response.content == b""
    assert all(h != mine for (h, _, _) in table.rows)
    assert sorted(h for (h, _, _) in table.rows) == sorted([hash_of(1), hash_of(2)])
    forget = [r for r in table.requests_with("DELETE") if "contributor_hash" in r.url.params]
    assert forget[-1].url.params["contributor_hash"] == f"eq.{mine}"
    assert set(forget[-1].url.params) == {"contributor_hash"}

    # Deleting again (nothing left) is still fine.
    assert client.delete("/v1/trends", headers=DEVICE_HEADERS).status_code == 204


def test_raw_device_id_never_reaches_supabase_or_the_log(client, table, caplog):
    caplog.set_level(logging.DEBUG)
    seed_contributors(table, 25, lambda n: [CELLO_IDS[0]])
    assert share(client, [CELLO_IDS[0]]).status_code == 204
    assert client.get("/v1/trends?instrument=cello").status_code == 200
    assert client.delete("/v1/trends", headers=DEVICE_HEADERS).status_code == 204
    table.fail_status = 500
    assert share(client, [CELLO_IDS[0]]).status_code == 502
    assert client.delete("/v1/trends", headers=DEVICE_HEADERS).status_code == 502

    mine = contributor_hash(SALT, RAW_DEVICE)
    assert table.requests
    for request in table.requests:
        sent = str(request.url) + request.content.decode() + json.dumps(dict(request.headers))
        assert RAW_DEVICE not in sent
        assert SALT not in sent
    for record in caplog.records:
        line = record.getMessage()
        for secret in (RAW_DEVICE, mine, SALT, SERVICE_KEY, "SECRET-DETAIL"):
            assert secret not in line
    # httpx's own request line is still there, with the hash blanked out.
    assert any("contributor_hash=eq.[hidden]" in r.getMessage() for r in caplog.records if r.name == "httpx")


# ------------------------------------------------------------------ retention


def test_old_rows_are_deleted_after_26_weeks(client, table, clock):
    monday = date(2026, 10, 5)
    kept = iso_week(monday - timedelta(weeks=26))
    gone = iso_week(monday - timedelta(weeks=27))
    table.seed(hash_of(1), "cello", kept, [CELLO_IDS[0]])
    table.seed(hash_of(2), "cello", gone, [CELLO_IDS[0]])
    table.seed(hash_of(3), "horn", "2025-W41", [HORN_ID])
    table.seed(hash_of(4), "cello", LAST_WEEK, [CELLO_IDS[0]])

    assert share(client, [CELLO_IDS[1]]).status_code == 204
    (prune,) = table.retention_deletes()
    assert prune.url.params["week"] == f"lt.{retention_cutoff(date(2026, 10, 11))}"
    weeks = {week for (_, _, week) in table.rows}
    assert kept in weeks and LAST_WEEK in weeks and THIS_WEEK in weeks
    assert gone not in weeks and "2025-W41" not in weeks

    # At most once an hour per instance.
    assert share(client, [CELLO_IDS[2]]).status_code == 204
    assert client.delete("/v1/trends", headers=DEVICE_HEADERS).status_code == 204
    assert len(table.retention_deletes()) == 1
    clock.now += 3600
    assert share(client, [CELLO_IDS[2]]).status_code == 204
    assert len(table.retention_deletes()) == 2


def test_retention_also_runs_on_reads(client, table):
    assert client.get("/v1/trends?instrument=cello").status_code == 200
    assert len(table.retention_deletes()) == 1


def test_a_failed_retention_delete_does_not_fail_the_post(client, table, clock):
    table.fail_status = 500
    table.fail_when = lambda request: request.method == "DELETE" and set(request.url.params) == {"week"}
    assert share(client, [CELLO_IDS[0]]).status_code == 204
    assert len(table.rows) == 1
    # It is tried again on the next request, without waiting an hour.
    assert share(client, [CELLO_IDS[1]]).status_code == 204
    assert len(table.retention_deletes()) == 2
    table.fail_status = None
    assert share(client, [CELLO_IDS[1]]).status_code == 204
    assert share(client, [CELLO_IDS[1]]).status_code == 204
    assert len(table.retention_deletes()) == 3


# ------------------------------------------------------------------ GET: threshold, tiers, no counts


def test_19_contributors_is_not_enough(client, table):
    seed_contributors(table, MIN_CONTRIBUTORS - 1, lambda n: [CELLO_IDS[0], CELLO_IDS[1]])
    response = client.get("/v1/trends?instrument=cello")
    assert response.status_code == 200
    assert response.json() == {"enough": False, "fromWeek": "2026-W34", "toWeek": THIS_WEEK, "trends": []}


def test_20_contributors_is_enough(client, table):
    seed_contributors(table, MIN_CONTRIBUTORS, lambda n: [CELLO_IDS[0]])
    response = client.get("/v1/trends?instrument=cello")
    assert response.status_code == 200
    assert response.json() == {
        "enough": True, "fromWeek": "2026-W34", "toWeek": THIS_WEEK,
        "trends": [{"excerptId": CELLO_IDS[0], "tier": "very-popular"}],
    }


def test_tiers_at_the_boundaries(client, table):
    def lists(n: int) -> list[str]:
        listed = [CELLO_IDS[9]]                      # everybody, so each contributor has a row
        if n < 8:
            listed.append(CELLO_IDS[0])              # 8 of 20 = 40 %  → very popular
        if n < 7:
            listed.append(CELLO_IDS[1])              # 7 of 20 = 35 %  → popular
        if n < 3:
            listed.append(CELLO_IDS[2])              # 3 of 20 = 15 %  → popular
        if n < 2:
            listed.append(CELLO_IDS[3])              # 2 of 20 = 10 %  → left out
        return listed

    seed_contributors(table, 20, lists)
    trends = client.get("/v1/trends?instrument=cello").json()["trends"]
    assert trends == [
        {"excerptId": CELLO_IDS[0], "tier": "very-popular"},
        {"excerptId": CELLO_IDS[9], "tier": "very-popular"},
        {"excerptId": CELLO_IDS[1], "tier": "popular"},
        {"excerptId": CELLO_IDS[2], "tier": "popular"},
    ]


def test_order_within_a_tier_does_not_leak_ranking(client, table):
    # CELLO_IDS[5] is listed by everyone, CELLO_IDS[4] by 9 of 20: both very popular,
    # and they come in id order, not most-listed first.
    seed_contributors(table, 20, lambda n: [CELLO_IDS[5]] + ([CELLO_IDS[4]] if n < 9 else []))
    trends = client.get("/v1/trends?instrument=cello").json()["trends"]
    assert [t["excerptId"] for t in trends] == [CELLO_IDS[4], CELLO_IDS[5]]


def test_answer_carries_no_counts_or_shares(client, table):
    seed_contributors(table, 37, lambda n: [CELLO_IDS[n % 3], CELLO_IDS[3]])
    body = client.get("/v1/trends?instrument=cello").json()
    assert set(body) == {"enough", "fromWeek", "toWeek", "trends"}
    assert body["trends"]
    for trend in body["trends"]:
        assert set(trend) == {"excerptId", "tier"}
        assert trend["tier"] in {"very-popular", "popular"}
    assert numbers_in(body) == []


def test_contributors_count_once_over_the_eight_week_window(client, table):
    # 10 contributors shared in three different weeks each: still 10, not enough.
    for week in ("2026-W34", "2026-W38", THIS_WEEK):
        seed_contributors(table, 10, lambda n: [CELLO_IDS[0]], week=week)
    body = client.get("/v1/trends?instrument=cello").json()
    assert body["enough"] is False
    # 10 more, outside the window (2026-W33): still not enough.
    seed_contributors(table, 10, lambda n: [CELLO_IDS[0]], week="2026-W33", start=10)
    client.app.state.trends.clear_cache()
    assert client.get("/v1/trends?instrument=cello").json()["enough"] is False
    # 10 more inside it (last week): 20.
    seed_contributors(table, 10, lambda n: [CELLO_IDS[1]], week=LAST_WEEK, start=10)
    client.app.state.trends.clear_cache()
    body = client.get("/v1/trends?instrument=cello").json()
    assert body["enough"] is True
    assert body["trends"] == [
        {"excerptId": CELLO_IDS[0], "tier": "very-popular"},
        {"excerptId": CELLO_IDS[1], "tier": "very-popular"},
    ]
    get = table.requests_with("GET")[-1]
    assert get.url.params["instrument"] == "eq.cello"
    assert get.url.params["week"] == "in.(" + ",".join(window_weeks(date(2026, 10, 11))) + ")"
    assert set(get.url.params["select"].split(",")) == {"contributor_hash", "excerpt_ids"}


def test_other_instruments_are_not_counted(client, table):
    seed_contributors(table, 20, lambda n: [HORN_ID], instrument="horn")
    assert client.get("/v1/trends?instrument=cello").json()["enough"] is False
    assert client.get("/v1/trends?instrument=horn").json()["trends"] == [{"excerptId": HORN_ID, "tier": "very-popular"}]


def test_excerpts_no_longer_in_the_catalogue_are_not_shown(client, table):
    seed_contributors(table, 20, lambda n: [CELLO_IDS[0], "cello-removed-since"])
    trends = client.get("/v1/trends?instrument=cello").json()["trends"]
    assert trends == [{"excerptId": CELLO_IDS[0], "tier": "very-popular"}]


def test_reads_are_paged(make_client, table, clock, wall):
    client = make_client()
    client.app.state.trends = TrendsService(
        SUPABASE_URL, SERVICE_KEY, SALT, transport=httpx.MockTransport(table), clock=clock, now=wall, page_rows=7,
    )
    seed_contributors(table, 23, lambda n: [CELLO_IDS[0]])
    body = client.get("/v1/trends?instrument=cello").json()
    assert body["enough"] is True
    pages = table.requests_with("GET")
    assert [r.url.params["offset"] for r in pages] == ["0", "7", "14", "21"]
    assert all(r.url.params["order"] == "contributor_hash.asc,week.asc" for r in pages)


def test_running_past_the_paging_stop_is_not_enough_rather_than_an_error(make_client, table, clock, wall, caplog):
    """The safety stop on paging (never reached by real data) answers 'not enough' with
    no excerpts — not a 502, and not a tier from a partial count — and logs no ids."""
    caplog.set_level(logging.DEBUG)
    client = make_client()
    client.app.state.trends = TrendsService(
        SUPABASE_URL, SERVICE_KEY, SALT, transport=httpx.MockTransport(table), clock=clock, now=wall,
        page_rows=5, max_paged_rows=10,
    )
    seed_contributors(table, 23, lambda n: [CELLO_IDS[0]])

    response = client.get("/v1/trends?instrument=cello")
    assert response.status_code == 200
    assert response.json() == {"enough": False, "fromWeek": "2026-W34", "toWeek": THIS_WEEK, "trends": []}
    assert [r.url.params["offset"] for r in table.requests_with("GET")] == ["0", "5"]  # stopped at 10 rows
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING and r.name == "auditioner.trends"]
    assert len(warnings) == 1 and "over 10 rows" in warnings[0]
    for line in (r.getMessage() for r in caplog.records):
        assert CELLO_IDS[0] not in line
        assert not any(hash_of(n) in line for n in range(23))
    # Kept like any answer, so the pages are not read again on every request.
    assert client.get("/v1/trends?instrument=cello").json()["enough"] is False
    assert len(table.requests_with("GET")) == 2


# ------------------------------------------------------------------ posts per network


def forwarded(address: str) -> dict[str, str]:
    return {**DEVICE_HEADERS, "X-Forwarded-For": address}


def test_posts_are_limited_per_network(make_client, table, clock, caplog):
    """Device ids are the app's to make up, so one network address gets a bounded number
    of posts an hour: 429 beyond it, nothing stored, and the address never logged."""
    caplog.set_level(logging.DEBUG)
    client = make_client(hourly_trends_post_limit=3)
    limiter = client.app.state.trends_network_limiter
    assert limiter.limit == 3 and limiter.window == HOUR_SECONDS
    client.app.state.trends_network_limiter = DailyLimiter(3, window_seconds=HOUR_SECONDS, clock=clock)

    for n in range(3):  # three "contributors" from one place
        assert share(client, [CELLO_IDS[n]], headers={"X-Device-Id": f"minted-{n}"}).status_code == 204
    fourth = share(client, [CELLO_IDS[3]], headers={"X-Device-Id": "minted-3"})
    assert fourth.status_code == 429
    assert fourth.json() == {"detail": MSG_TOO_MANY_REQUESTS}
    assert len(table.rows) == 3
    assert len(table.requests_with("POST")) == 3

    # Another address (the last entry of X-Forwarded-For, which Google's front end appends)
    # has its own allowance; entries a client puts in front of it change nothing.
    assert share(client, [CELLO_IDS[0]], headers=forwarded("203.0.113.7")).status_code == 204
    assert share(client, [CELLO_IDS[0]], headers=forwarded("10.1.2.3, 203.0.113.7")).status_code == 204
    assert share(client, [CELLO_IDS[0]], headers=forwarded(" 10.9.9.9 ,203.0.113.7")).status_code == 204
    assert share(client, [CELLO_IDS[0]], headers=forwarded("198.51.100.4, 203.0.113.7")).status_code == 429
    assert share(client, [CELLO_IDS[0]], headers=forwarded("203.0.113.8")).status_code == 204
    # A sliding hour.
    clock.now += HOUR_SECONDS + 1
    assert share(client, [CELLO_IDS[0]], headers={"X-Device-Id": "minted-3"}).status_code == 204

    for record in caplog.records:
        line = record.getMessage()
        assert "203.0.113" not in line and "testclient" not in line


def test_bad_posts_do_not_count_against_the_network(make_client, table):
    client = make_client(hourly_trends_post_limit=1)
    for week in ("2026-W39", "nope", ""):
        assert share(client, [CELLO_IDS[0]], week=week).status_code == 400
    assert share(client, [CELLO_IDS[0]], instrument="kazoo").status_code == 400
    assert share(client, CELLO_IDS[:51]).status_code == 400
    assert share(client, [CELLO_IDS[0]], headers={}).status_code == 400
    assert share(client, [CELLO_IDS[0]]).status_code == 204
    assert share(client, [CELLO_IDS[1]]).status_code == 429


def test_unconfigured_posts_do_not_count_against_the_network(settings_factory, catalog_dir):
    app = create_app(settings_factory(catalog_dir=catalog_dir, hourly_trends_post_limit=1))
    client = TestClient(app)
    for _ in range(3):
        assert share(client, [CELLO_IDS[0]]).status_code == 503


def test_network_limit_comes_from_the_environment():
    assert Settings.from_env({}).hourly_trends_post_limit == 20
    assert Settings.from_env({"HOURLY_TRENDS_POST_LIMIT": " 5 "}).hourly_trends_post_limit == 5
    with pytest.raises(ValueError):
        Settings.from_env({"HOURLY_TRENDS_POST_LIMIT": "lots"})


# ------------------------------------------------------------------ cache and errors


def test_answers_are_cached_for_an_hour(client, table, clock):
    seed_contributors(table, 20, lambda n: [CELLO_IDS[0]])
    first = client.get("/v1/trends?instrument=cello")
    assert first.headers["cache-control"] == "public, max-age=3600"
    seed_contributors(table, 20, lambda n: [CELLO_IDS[1]], start=20)
    clock.now += 3599
    assert client.get("/v1/trends?instrument=cello").json() == first.json()
    assert len(table.requests_with("GET")) == 1
    # Another instrument has its own entry.
    client.get("/v1/trends?instrument=horn")
    assert len(table.requests_with("GET")) == 2
    clock.now += 1
    fresh = client.get("/v1/trends?instrument=cello").json()
    assert len(table.requests_with("GET")) == 3
    assert {"excerptId": CELLO_IDS[1], "tier": "very-popular"} in fresh["trends"]


def test_a_new_week_is_a_new_answer(client, table, wall):
    client.get("/v1/trends?instrument=cello")
    wall.moment = NOW + timedelta(days=1)  # Monday: 2026-W42
    body = client.get("/v1/trends?instrument=cello").json()
    assert body["toWeek"] == "2026-W42" and body["fromWeek"] == "2026-W35"
    assert len(table.requests_with("GET")) == 2


def test_errors_are_502_and_not_cached(client, table, caplog):
    caplog.set_level(logging.DEBUG)
    table.fail_status = 503
    response = client.get("/v1/trends?instrument=cello")
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_TRENDS_UPSTREAM}
    table.fail_status = None
    assert client.get("/v1/trends?instrument=cello").status_code == 200
    assert len(table.requests_with("GET")) == 2
    assert all("SECRET-DETAIL" not in record.getMessage() for record in caplog.records)


@pytest.mark.parametrize("error", [httpx.ConnectError("boom"), httpx.ReadTimeout("slow")])
def test_unreachable_supabase_is_502(client, table, error):
    table.raise_error = error
    for response in (
        share(client, [CELLO_IDS[0]]),
        client.delete("/v1/trends", headers=DEVICE_HEADERS),
        client.get("/v1/trends?instrument=cello"),
    ):
        assert response.status_code == 502
        assert response.json() == {"detail": MSG_TRENDS_UPSTREAM}


@pytest.mark.parametrize("body", [b"not json", b'{"rows": []}', b"[1, 2]"])
def test_unexpected_answers_are_502(client, table, body):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, content=body)
        return httpx.Response(204)

    client.app.state.trends = TrendsService(SUPABASE_URL, SERVICE_KEY, SALT, transport=httpx.MockTransport(handler))
    response = client.get("/v1/trends?instrument=cello")
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_TRENDS_UPSTREAM}


def test_a_failed_share_is_502(client, table):
    table.fail_status = 500
    table.fail_when = lambda request: request.method == "POST"
    response = share(client, [CELLO_IDS[0]])
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_TRENDS_UPSTREAM}
    assert table.rows == {}


def test_the_real_catalogue_is_used_when_present(settings_factory, table, clock, wall):
    # content/catalog in the repo: any published cello id is accepted, nothing else.
    from conftest import REPO_CATALOG

    cello_file = REPO_CATALOG / "cello.json"
    assert cello_file.is_file()
    published = [e["id"] for e in json.loads(cello_file.read_text(encoding="utf-8"))["excerpts"]
                 if e.get("listingStatus") == "published"]
    settings = settings_factory(supabase_url=SUPABASE_URL, supabase_service_role_key=SERVICE_KEY,
                                trends_salt=SALT, catalog_dir=REPO_CATALOG)
    app = create_app(settings)
    app.state.trends = TrendsService(SUPABASE_URL, SERVICE_KEY, SALT, transport=httpx.MockTransport(table),
                                     clock=clock, now=wall)
    client = TestClient(app)
    assert share(client, published[:2] + ["cello-not-a-real-id"]).status_code == 204
    (row,) = table.rows.values()
    assert row["excerpt_ids"] == sorted(published[:2])
