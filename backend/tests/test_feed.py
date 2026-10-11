"""GET /v1/auditions and GET /v1/recommendations against a fake PostgREST
(httpx.MockTransport, no network). Orchestras, works and excerpt ids here are
fictional fixtures; no bar numbers appear anywhere (CLAUDE.md honesty contract)."""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from datetime import date
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.feed import (
    MSG_FEED_OFF,
    MSG_FEED_UPSTREAM,
    POSITION_CLASSES,
    POSITION_IDS,
    REGION_IDS,
    FeedService,
    evidence,
    position_class,
)
from app.instruments import INSTRUMENT_IDS
from app.main import create_app

SUPABASE_URL = "https://feedtest.supabase.co"
SERVICE_KEY = "service-role-key-for-feed-tests"
TODAY = date(2026, 10, 11)

# The Swift contract (ios/Auditioner/Core/Networking/APIClient.swift), field for field.
FEED_VACANCY_KEYS = {
    "id", "orchestra", "orchestraId", "region", "position", "instrument", "applicationDeadline",
    "auditionDates", "listCompleteness", "sourceURL", "lastCheckedAt", "items",
}
FEED_ITEM_KEYS = {"rawText", "category", "round", "excerptId"}
RECOMMENDATION_KEYS = {"excerptId", "tier", "share", "listCount", "totalLists", "openNow", "evidence"}
APP_REGIONS = {"north-america", "europe-german", "europe-other", "uk", "asia-pacific", "other"}  # ProfileOptions.swift
APP_POSITIONS = {"principal", "assistant-principal", "section", "utility", "second", "high", "low", "concertmaster", "any"}


def vid(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"


def vacancy_row(n: int = 1, **changes: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "id": vid(n),
        "orchestra_id": "example-philharmonic",
        "orchestra_name": "Example Philharmonic",
        "country": "US",
        "region": "north-america",
        "city": "Exampleton",
        "orchestra_type": "professional",
        "position": "Section Cello",
        "position_class": "section",
        "instrument": "cello",
        "chair": "",
        "application_deadline": "2026-11-15",
        "audition_dates": [
            {"value": "2027-01-12", "sourceLineIds": ["L0004"]},
            {"value": "2027-01-10", "sourceLineIds": ["L0003"]},
        ],
        "list_completeness": "full",
        "source_url": "https://www.example-philharmonic.test/auditions/cello-list.pdf",
        "first_seen_at": "2026-09-01T03:17:00+00:00",
        "last_seen_at": "2026-10-09T03:17:42.123456+00:00",
    }
    row.update(changes)
    return row


def item_row(n: int, vacancy: int = 1, ordinal: int = 1, **changes: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "id": f"10000000-0000-4000-8000-{n:012d}",
        "vacancy_id": vid(vacancy),
        "ordinal": ordinal,
        "raw_text": f"Testmann: Fixture Symphony No. {n}, second movement",
        "category": "excerpt",
        "round": "Preliminary",
        "excerpt_id": f"cello-fixture-{n}",
        "review_status": "published",
    }
    row.update(changes)
    return row


def rec_row(excerpt: str, **changes: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "excerpt_id": excerpt,
        "score": 0.61234,
        "share": 0.7,
        "prior_share": 0.5,
        "weighted_hits": 4.2,
        "weighted_lists": 6.1,
        "n_lists_with_excerpt": 5,
        "n_lists": 8,
        "earliest_list_date": "2024-03-01",
        "latest_list_date": "2026-09-30",
        "tier": "core",
        "evidence": "On 5 of 8 section cello lists (north-america), 2024–2026",
    }
    row.update(changes)
    return row


class FakeSupabase:
    """Just enough PostgREST: filters by eq./in., the published filter on items and
    on the vacancies table, select, limit/offset, and the RPC. Records every request.

    `vacancies` stand for both the vacancies table and the open_auditions view. The
    fake view does *not* filter on review_status (a row without one counts as
    published), so a test can play a view that was redefined without its filter."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.vacancies: list[dict[str, Any]] = []
        self.items: list[dict[str, Any]] = []
        self.recommendations: list[dict[str, Any]] = []
        self.open_now: list[dict[str, Any]] = []
        self.frequency: list[dict[str, Any]] = []
        self.fail_status: int | None = None
        self.fail_body: bytes = b'{"message": "relation does not exist: SECRET-DETAIL"}'
        self.fail_path: str | None = None
        self.raise_error: Exception | None = None
        self.open_auditions_ignores_instrument = False

    # -- helpers

    @staticmethod
    def _eq(rows: list[dict[str, Any]], params: httpx.QueryParams, *columns: str) -> list[dict[str, Any]]:
        for column in columns:
            if column in params:
                rows = [r for r in rows if f"eq.{r.get(column)}" == params[column]]
        return rows

    @staticmethod
    def _in(params: httpx.QueryParams, column: str) -> list[str]:
        return params[column].removeprefix("in.(").removesuffix(")").split(",")

    @staticmethod
    def _page(rows: list[dict[str, Any]], params: httpx.QueryParams) -> list[dict[str, Any]]:
        offset = int(params.get("offset", "0"))
        limit = int(params["limit"]) if "limit" in params else len(rows)
        rows = rows[offset:offset + limit]
        if "select" in params:
            columns = params["select"].split(",")
            rows = [{c: r.get(c) for c in columns} for r in rows]
        return rows

    def paths(self) -> list[str]:
        return [r.url.path for r in self.requests]

    def requests_to(self, path: str) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path == path]

    # -- handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_error is not None:
            raise self.raise_error
        path = request.url.path
        if self.fail_status is not None and (self.fail_path is None or path == self.fail_path):
            return httpx.Response(self.fail_status, content=self.fail_body)
        params = request.url.params
        if path == "/rest/v1/open_auditions" and request.method == "GET":
            columns = ("region",) if self.open_auditions_ignores_instrument else ("instrument", "region")
            rows = self._eq(self.vacancies, params, *columns)
            return httpx.Response(200, json=self._page(rows, params))
        if path == "/rest/v1/vacancies" and request.method == "GET":
            wanted = self._in(params, "id")
            rows = [{"review_status": "published", **r} for r in self.vacancies if r.get("id") in wanted]
            rows = self._eq(rows, params, "review_status", "instrument")
            rows.sort(key=lambda r: str(r["id"]))
            return httpx.Response(200, json=self._page(rows, params))
        if path == "/rest/v1/vacancy_items" and request.method == "GET":
            wanted = self._in(params, "vacancy_id")
            rows = [r for r in self.items if r["vacancy_id"] in wanted]
            rows = self._eq(rows, params, "review_status")
            rows.sort(key=lambda r: (r["vacancy_id"], r["ordinal"], r["id"]))
            return httpx.Response(200, json=self._page(rows, params))
        if path == "/rest/v1/rpc/excerpt_recommendations" and request.method == "POST":
            return httpx.Response(200, json=self.recommendations)
        if path == "/rest/v1/excerpt_open_now" and request.method == "GET":
            rows = self._eq(self.open_now, params, "instrument")
            return httpx.Response(200, json=self._page(rows, params))
        if path == "/rest/v1/excerpt_frequency" and request.method == "GET":
            rows = self._eq(self.frequency, params, "instrument", "position_class")
            return httpx.Response(200, json=self._page(rows, params))
        return httpx.Response(404, json={"message": f"unexpected {request.method} {path}"})


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def fake() -> FakeSupabase:
    return FakeSupabase()


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def make_client(settings_factory: Callable[..., Settings], fake: FakeSupabase, clock: Clock):
    def factory(**service_options: Any) -> TestClient:
        settings = settings_factory(supabase_url=SUPABASE_URL, supabase_service_role_key=SERVICE_KEY)
        app = create_app(settings)
        assert app.state.feed.configured
        app.state.feed = FeedService(
            settings.supabase_url,
            settings.supabase_service_role_key,
            transport=httpx.MockTransport(fake),
            clock=clock,
            today=lambda: TODAY,
            **service_options,
        )
        return TestClient(app)

    return factory


@pytest.fixture
def feed_client(make_client) -> TestClient:
    return make_client()


# ------------------------------------------------------------------ not configured


@pytest.mark.parametrize(
    "path",
    [
        "/v1/auditions?instrument=cello&region=north-america",
        "/v1/auditions?instrument=cello",
        "/v1/recommendations?instrument=cello&position=section&region=uk",
    ],
)
def test_503_when_supabase_is_not_configured(client, path):
    response = client.get(path)
    assert response.status_code == 503
    assert response.json() == {"detail": MSG_FEED_OFF}


@pytest.mark.parametrize("missing", ["supabase_url", "supabase_service_role_key"])
def test_503_when_only_one_value_is_set(settings_factory, missing):
    values = {"supabase_url": SUPABASE_URL, "supabase_service_role_key": SERVICE_KEY}
    values[missing] = ""
    app = create_app(settings_factory(**values))
    assert not app.state.feed.configured
    response = TestClient(app).get("/v1/auditions?instrument=cello")
    assert response.status_code == 503
    assert response.json() == {"detail": MSG_FEED_OFF}


def test_bad_parameters_are_400_even_when_not_configured(client):
    response = client.get("/v1/auditions?instrument=kazoo")
    assert response.status_code == 400
    assert response.json() == {"detail": "Unknown instrument 'kazoo'. Pick your instrument in the app and try again."}


# ------------------------------------------------------------------ parameters


@pytest.mark.parametrize("value", ["", "kazoo", "other", "saxophone", "cello;drop", "violin,viola"])
def test_unknown_instrument_is_400(feed_client, fake, value):
    for path in (f"/v1/auditions?instrument={value}", f"/v1/recommendations?instrument={value}&position=section"):
        response = feed_client.get(path)
        assert response.status_code == 400
        assert set(response.json()) == {"detail"}
        assert response.json()["detail"].startswith("Unknown instrument")
    assert fake.requests == []


def test_missing_instrument_is_400(feed_client, fake):
    for path in ("/v1/auditions", "/v1/recommendations?position=section"):
        response = feed_client.get(path)
        assert response.status_code == 400
        assert response.json() == {"detail": "Unknown instrument '(blank)'. Pick your instrument in the app and try again."}
    assert fake.requests == []


def test_every_catalogue_instrument_is_accepted(feed_client, fake):
    assert len(INSTRUMENT_IDS) == 22
    for instrument in INSTRUMENT_IDS:
        assert feed_client.get(f"/v1/auditions?instrument={instrument}").status_code == 200
        assert feed_client.get(f"/v1/recommendations?instrument={instrument}&position=section&region=uk").status_code == 200


def test_instrument_is_normalised(feed_client, fake):
    assert feed_client.get("/v1/auditions?instrument=%20Cello%20").status_code == 200
    assert fake.requests_to("/rest/v1/open_auditions")[0].url.params["instrument"] == "eq.cello"


@pytest.mark.parametrize("value", ["europe", "North America", "all", "us", "north_america"])
def test_unknown_region_is_400(feed_client, fake, value):
    for path in (f"/v1/auditions?instrument=cello&region={value}",
                 f"/v1/recommendations?instrument=cello&position=section&region={value}"):
        response = feed_client.get(path)
        assert response.status_code == 400
        assert response.json()["detail"].startswith("Unknown region")
        assert "Settings" in response.json()["detail"]
    assert fake.requests == []


def test_regions_match_the_app(feed_client):
    assert set(REGION_IDS) == APP_REGIONS
    for region in APP_REGIONS:
        assert feed_client.get(f"/v1/auditions?instrument=cello&region={region}").status_code == 200


@pytest.mark.parametrize("value", ["", "first", "tutti", "Principal Cello", "assistant_principal"])
def test_unknown_or_missing_position_is_400(feed_client, fake, value):
    response = feed_client.get(f"/v1/recommendations?instrument=cello&position={value}&region=uk")
    assert response.status_code == 400
    assert response.json()["detail"].startswith("Unknown position")
    response = feed_client.get("/v1/recommendations?instrument=cello&region=uk")
    assert response.status_code == 400
    assert fake.requests == []


def test_feed_needs_no_device_header(feed_client):
    # Read-only and cached: unlike scans, no X-Device-Id is required.
    assert feed_client.get("/v1/auditions?instrument=cello").status_code == 200


# ------------------------------------------------------------------ position mapping


def test_positions_match_the_app():
    assert set(POSITION_IDS) == APP_POSITIONS


@pytest.mark.parametrize(
    ("position", "instrument", "expected"),
    [
        ("principal", "cello", "principal"),
        ("concertmaster", "violin", "principal"),
        ("assistant-principal", "cello", "assistant-principal"),
        ("section", "cello", "section"),
        ("utility", "horn", "section"),
        ("any", "cello", "section"),
        ("high", "horn", "principal"),
        ("low", "horn", "other"),
        ("second", "oboe", "other"),
        ("second", "horn", "other"),
        ("second", "harp", "other"),
        ("second", "violin", "section"),
        ("second", "double-bass", "section"),
    ],
)
def test_position_classes(feed_client, fake, position, instrument, expected):
    assert position_class(position, instrument) == expected
    response = feed_client.get(f"/v1/recommendations?instrument={instrument}&position={position}&region=uk")
    assert response.status_code == 200
    body = json.loads(fake.requests_to("/rest/v1/rpc/excerpt_recommendations")[-1].content)
    assert body == {"p_instrument": instrument, "p_position_class": expected, "p_region": "uk"}


def test_every_position_maps_to_a_database_class():
    for instrument in INSTRUMENT_IDS:
        for position in POSITION_IDS:
            assert position_class(position, instrument) in POSITION_CLASSES


# ------------------------------------------------------------------ /v1/auditions


def test_auditions_map_to_the_app_contract(feed_client, fake):
    fake.vacancies = [vacancy_row(1)]
    fake.items = [
        item_row(2, ordinal=2, category="solo", round="", excerpt_id=None,
                 raw_text="A concerto of your choice, first movement"),
        item_row(1, ordinal=1),
    ]

    response = feed_client.get("/v1/auditions?instrument=cello&region=north-america")

    assert response.status_code == 200
    assert response.json() == {
        "auditions": [
            {
                "id": vid(1),
                "orchestra": "Example Philharmonic",
                "orchestraId": "example-philharmonic",
                "region": "north-america",
                "position": "Section Cello",
                "instrument": "cello",
                "applicationDeadline": "2026-11-15",
                "auditionDates": ["2027-01-10", "2027-01-12"],
                "listCompleteness": "full",
                "sourceURL": "https://www.example-philharmonic.test/auditions/cello-list.pdf",
                "lastCheckedAt": "2026-10-09",
                "items": [
                    {"rawText": "Testmann: Fixture Symphony No. 1, second movement", "category": "excerpt",
                     "round": "Preliminary", "excerptId": "cello-fixture-1"},
                    {"rawText": "A concerto of your choice, first movement", "category": "solo",
                     "round": "", "excerptId": None},
                ],
            }
        ]
    }


def test_auditions_ask_only_for_open_published_rows(feed_client, fake):
    fake.vacancies = [vacancy_row(1)]
    fake.items = [item_row(1)]
    assert feed_client.get("/v1/auditions?instrument=cello").status_code == 200

    (vacancies,) = fake.requests_to("/rest/v1/open_auditions")
    params = vacancies.url.params
    assert vacancies.method == "GET"
    assert params["instrument"] == "eq.cello"
    assert "region" not in params  # no region asked → every region
    # Open: deadline from yesterday (UTC) on, or no deadline and seen in the last 60 days.
    assert params["or"] == (
        "(application_deadline.gte.2026-10-10,and(application_deadline.is.null,last_seen_at.gte.2026-08-12))"
    )
    assert params["order"] == "application_deadline.asc.nullslast,orchestra_name.asc,id.asc"
    assert params["limit"] == "500"

    (check,) = fake.requests_to("/rest/v1/vacancies")
    assert check.method == "GET"
    assert check.url.params["select"] == "id"
    assert check.url.params["id"] == f"in.({vid(1)})"
    assert check.url.params["review_status"] == "eq.published"
    assert check.url.params["instrument"] == "eq.cello"

    (items,) = fake.requests_to("/rest/v1/vacancy_items")
    assert items.url.params["review_status"] == "eq.published"
    assert items.url.params["vacancy_id"] == f"in.({vid(1)})"
    assert fake.paths() == ["/rest/v1/open_auditions", "/rest/v1/vacancies", "/rest/v1/vacancy_items"]
    for request in fake.requests:
        assert request.headers["apikey"] == SERVICE_KEY
        assert request.headers["authorization"] == f"Bearer {SERVICE_KEY}"


def test_region_filter_is_sent(feed_client, fake):
    fake.vacancies = [vacancy_row(1, region="uk"), vacancy_row(2)]
    response = feed_client.get("/v1/auditions?instrument=cello&region=uk")
    assert [v["id"] for v in response.json()["auditions"]] == [vid(1)]
    assert fake.requests_to("/rest/v1/open_auditions")[0].url.params["region"] == "eq.uk"


def test_unpublished_items_never_reach_the_app(feed_client, fake):
    fake.vacancies = [vacancy_row(1)]
    fake.items = [
        item_row(1, ordinal=1),
        item_row(2, ordinal=2, review_status="in_review", raw_text="NOT REVIEWED YET"),
        item_row(3, ordinal=3, review_status="rejected", raw_text="REJECTED LINE"),
        item_row(4, vacancy=99, ordinal=1, raw_text="ITEM OF ANOTHER VACANCY"),
    ]
    response = feed_client.get("/v1/auditions?instrument=cello")
    items = response.json()["auditions"][0]["items"]
    assert [i["rawText"] for i in items] == ["Testmann: Fixture Symphony No. 1, second movement"]
    assert "NOT REVIEWED" not in response.text and "REJECTED" not in response.text and "ANOTHER" not in response.text


@pytest.mark.parametrize("status", ["in_review", "draft", "rejected"])
def test_unpublished_vacancies_never_reach_the_app_even_if_the_view_changes(feed_client, fake, caplog, status):
    # The fake view ignores review_status, like an open_auditions view redefined without
    # its filter: the check against the vacancies table still keeps the row out.
    fake.vacancies = [vacancy_row(1), vacancy_row(2, review_status=status, position="UNPUBLISHED POSITION")]
    fake.items = [item_row(1, vacancy=1), item_row(2, vacancy=2, raw_text="ITEM OF AN UNPUBLISHED VACANCY")]
    with caplog.at_level(logging.WARNING, logger="auditioner.feed"):
        response = feed_client.get("/v1/auditions?instrument=cello")
    assert [v["id"] for v in response.json()["auditions"]] == [vid(1)]
    assert "UNPUBLISHED" not in response.text
    (items,) = fake.requests_to("/rest/v1/vacancy_items")
    assert items.url.params["vacancy_id"] == f"in.({vid(1)})"  # never even asked for its items
    assert "1 vacancies the vacancies table does not mark published" in caplog.text


def test_vacancy_of_another_instrument_is_left_out(feed_client, fake):
    # Same lock: a view that stopped filtering by instrument cannot mix instruments.
    fake.vacancies = [vacancy_row(1), vacancy_row(2, instrument="viola", position="Section Viola")]
    fake.open_auditions_ignores_instrument = True
    response = feed_client.get("/v1/auditions?instrument=cello")
    assert [v["id"] for v in response.json()["auditions"]] == [vid(1)]


def test_duplicate_rows_are_sent_once(feed_client, fake):
    fake.vacancies = [vacancy_row(1), vacancy_row(1)]
    fake.items = [item_row(1)]
    auditions = feed_client.get("/v1/auditions?instrument=cello").json()["auditions"]
    assert [v["id"] for v in auditions] == [vid(1)]
    assert len(auditions[0]["items"]) == 1


def test_items_keep_the_list_order(feed_client, fake):
    fake.vacancies = [vacancy_row(1), vacancy_row(2, application_deadline="2026-12-01")]
    fake.items = [item_row(n, vacancy=1 if n < 4 else 2, ordinal=10 - n) for n in range(1, 7)]
    auditions = feed_client.get("/v1/auditions?instrument=cello").json()["auditions"]
    assert [i["excerptId"] for i in auditions[0]["items"]] == ["cello-fixture-3", "cello-fixture-2", "cello-fixture-1"]
    assert [i["excerptId"] for i in auditions[1]["items"]] == ["cello-fixture-6", "cello-fixture-5", "cello-fixture-4"]


def test_vacancy_without_published_items_has_an_empty_list(feed_client, fake):
    fake.vacancies = [vacancy_row(1, list_completeness="revealed_on_invitation")]
    vacancy = feed_client.get("/v1/auditions?instrument=cello").json()["auditions"][0]
    assert vacancy["items"] == []
    assert vacancy["listCompleteness"] == "revealed_on_invitation"


def test_items_are_fetched_in_chunks_and_pages(make_client, fake):
    client = make_client(item_chunk=20, page_rows=2)
    fake.vacancies = [vacancy_row(n, application_deadline=f"2026-11-{(n % 28) + 1:02d}") for n in range(1, 46)]
    fake.items = [item_row(100 + k, vacancy=7, ordinal=k) for k in range(1, 6)]

    auditions = client.get("/v1/auditions?instrument=cello").json()["auditions"]

    assert len(auditions) == 45
    item_requests = fake.requests_to("/rest/v1/vacancy_items")
    chunks = {r.url.params["vacancy_id"] for r in item_requests}
    assert len(chunks) == 3  # 20 + 20 + 5 ids
    assert all(len(c.removeprefix("in.(").removesuffix(")").split(",")) <= 20 for c in chunks)
    # vacancy 7's five items come in pages of two: offsets 0, 2, 4.
    first_chunk = [r for r in item_requests if vid(7) in r.url.params["vacancy_id"]]
    assert [r.url.params["offset"] for r in first_chunk] == ["0", "2", "4"]
    seventh = next(v for v in auditions if v["id"] == vid(7))
    assert [i["excerptId"] for i in seventh["items"]] == [f"cello-fixture-{100 + k}" for k in range(1, 6)]


def test_no_item_request_when_there_are_no_open_auditions(feed_client, fake):
    assert feed_client.get("/v1/auditions?instrument=tuba").json() == {"auditions": []}
    assert fake.paths() == ["/rest/v1/open_auditions"]


def test_chair_is_shown_with_the_position(feed_client, fake):
    fake.vacancies = [
        vacancy_row(1, instrument="horn", position="Horn", chair="Third horn"),
        vacancy_row(2, instrument="horn", position="Second Horn", chair="second horn"),
    ]
    positions = [v["position"] for v in feed_client.get("/v1/auditions?instrument=horn").json()["auditions"]]
    assert positions == ["Horn (Third horn)", "Second Horn"]


def test_dates_are_only_passed_on_when_they_are_real_dates(feed_client, fake):
    fake.vacancies = [
        vacancy_row(
            1,
            application_deadline=None,
            audition_dates=["2027-02-03", {"value": ""}, {"value": "2027-02-30"}, {"value": "early 2027"},
                            {"value": "2027-02-03", "sourceLineIds": ["L0009"]}, 20270204, None],
            last_seen_at=None,
        ),
        vacancy_row(2, audition_dates={"value": "2027-01-01"}, application_deadline="2026-13-01",
                    last_seen_at="2026-10-01 03:00:00+00"),
    ]
    first, second = feed_client.get("/v1/auditions?instrument=cello").json()["auditions"]
    assert first["applicationDeadline"] is None
    assert first["auditionDates"] == ["2027-02-03"]
    assert first["lastCheckedAt"] is None
    assert second["auditionDates"] == []
    assert second["applicationDeadline"] is None
    assert second["lastCheckedAt"] == "2026-10-01"


def test_rows_missing_a_required_field_are_left_out(feed_client, fake, caplog):
    fake.vacancies = [
        vacancy_row(1),
        vacancy_row(2, position=""),
        vacancy_row(3, source_url="file:uploaded-list.pdf"),
        vacancy_row(4, id="not-a-uuid"),
        vacancy_row(5, orchestra_name=None),  # falls back to the registry id
        vacancy_row(6, orchestra_name=None, orchestra_id=None),
        vacancy_row(7, region=None, list_completeness=None, instrument="cello"),
    ]
    fake.items = [item_row(1, vacancy=1, raw_text="   ")]  # no evidence → not shown
    with caplog.at_level(logging.WARNING, logger="auditioner.feed"):
        auditions = feed_client.get("/v1/auditions?instrument=cello").json()["auditions"]
    assert [v["id"] for v in auditions] == [vid(1), vid(5), vid(7)]
    assert auditions[0]["items"] == []
    assert auditions[1]["orchestra"] == "example-philharmonic"
    assert auditions[2]["region"] is None
    assert auditions[2]["listCompleteness"] == "unknown"
    assert "skipped 4" in caplog.text
    for vacancy in auditions:
        assert set(vacancy) == FEED_VACANCY_KEYS
        assert isinstance(vacancy["auditionDates"], list)
        for item in vacancy["items"]:
            assert set(item) == FEED_ITEM_KEYS


# ------------------------------------------------------------------ /v1/recommendations


def test_recommendations_map_to_the_app_contract(feed_client, fake):
    fake.recommendations = [
        rec_row("cello-fixture-a"),
        rec_row("cello-fixture-b", score=0.25, tier="common", n_lists_with_excerpt=0,
                earliest_list_date=None, latest_list_date=None),
        rec_row("cello-fixture-c", score="0.05", tier="occasional", n_lists_with_excerpt=1,
                earliest_list_date="2025-02-01", latest_list_date="2025-02-01"),
    ]
    fake.open_now = [
        {"excerpt_id": "cello-fixture-a", "instrument": "cello", "open_vacancies": 3},
        {"excerpt_id": "cello-fixture-z", "instrument": "cello", "open_vacancies": 1},
        {"excerpt_id": "viola-fixture-a", "instrument": "viola", "open_vacancies": 9},
    ]

    response = feed_client.get("/v1/recommendations?instrument=cello&position=section&region=north-america")

    assert response.status_code == 200
    assert response.json() == {
        "recommendations": [
            {"excerptId": "cello-fixture-a", "tier": "core", "share": 0.6123, "listCount": 5, "totalLists": 8,
             "openNow": 3, "evidence": "On 5 of 8 section cello lists in North America, 2024–2026"},
            {"excerptId": "cello-fixture-b", "tier": "common", "share": 0.25, "listCount": 0, "totalLists": 8,
             "openNow": 0,
             "evidence": "Not on any of the 8 section cello lists we have in North America — the tier comes from other regions"},
            {"excerptId": "cello-fixture-c", "tier": "occasional", "share": 0.05, "listCount": 1, "totalLists": 8,
             "openNow": 0, "evidence": "On 1 of 8 section cello lists in North America, 2025"},
        ]
    }
    (rpc,) = fake.requests_to("/rest/v1/rpc/excerpt_recommendations")
    assert rpc.method == "POST"
    assert json.loads(rpc.content) == {"p_instrument": "cello", "p_position_class": "section", "p_region": "north-america"}
    (open_now,) = fake.requests_to("/rest/v1/excerpt_open_now")
    assert open_now.url.params["instrument"] == "eq.cello"
    assert "excerpt_frequency" not in "".join(fake.paths())


def test_recommendation_rows_with_missing_values_are_left_out(feed_client, fake):
    fake.recommendations = [
        rec_row("cello-fixture-a"),
        rec_row("", tier="core"),
        rec_row("cello-fixture-b", tier="legendary"),
        rec_row("cello-fixture-c", score=None),
        rec_row("cello-fixture-d", n_lists=None),
        rec_row("cello-fixture-e", score="NaN"),
        rec_row("cello-fixture-g", score="Infinity"),
        rec_row("cello-fixture-f", n_lists_with_excerpt=1.5),
    ]
    found = feed_client.get("/v1/recommendations?instrument=cello&position=section&region=uk").json()["recommendations"]
    assert [r["excerptId"] for r in found] == ["cello-fixture-a"]
    assert set(found[0]) == RECOMMENDATION_KEYS


def test_share_stays_between_zero_and_one(feed_client, fake):
    fake.recommendations = [rec_row("cello-fixture-a", score=1.2), rec_row("cello-fixture-b", score=-0.1, tier="occasional")]
    found = feed_client.get("/v1/recommendations?instrument=cello&position=section&region=uk").json()["recommendations"]
    assert [r["share"] for r in found] == [1.0, 0.0]


def test_recommendations_for_every_region(feed_client, fake):
    def freq(region: str, excerpt: str, hits: float, lists: float, k: int, n: int, first: str, last: str) -> dict:
        return {"instrument": "cello", "position_class": "principal", "region": region, "excerpt_id": excerpt,
                "weighted_hits": hits, "weighted_lists": lists, "n_lists_with_excerpt": k, "n_lists": n,
                "share": hits / lists, "earliest_list_date": first, "latest_list_date": last}

    fake.frequency = [
        freq("north-america", "cello-fixture-a", 3.0, 6.0, 4, 7, "2024-01-15", "2026-05-01"),
        freq("north-america", "cello-fixture-b", 1.0, 6.0, 1, 7, "2026-02-01", "2026-02-01"),
        freq("uk", "cello-fixture-a", 1.5, 2.0, 2, 3, "2023-06-01", "2025-06-01"),
        freq("uk", "cello-fixture-c", 0.2, 2.0, 1, 3, "2023-01-01", "2023-01-01"),
        {**freq("uk", "cello-fixture-a", 9.0, 9.0, 9, 9, "2020-01-01", "2020-01-01"), "position_class": "section"},
    ]
    fake.open_now = [{"excerpt_id": "cello-fixture-c", "instrument": "cello", "open_vacancies": 2}]

    response = feed_client.get("/v1/recommendations?instrument=cello&position=principal")

    assert response.status_code == 200
    assert response.json()["recommendations"] == [
        {"excerptId": "cello-fixture-a", "tier": "core", "share": 0.5625, "listCount": 6, "totalLists": 10,
         "openNow": 0, "evidence": "On 6 of 10 principal cello lists across all regions, 2023–2026"},
        {"excerptId": "cello-fixture-b", "tier": "occasional", "share": 0.125, "listCount": 1, "totalLists": 10,
         "openNow": 0, "evidence": "On 1 of 10 principal cello lists across all regions, 2026"},
        {"excerptId": "cello-fixture-c", "tier": "occasional", "share": 0.025, "listCount": 1, "totalLists": 10,
         "openNow": 2, "evidence": "On 1 of 10 principal cello lists across all regions, 2023"},
    ]
    assert "/rest/v1/rpc/excerpt_recommendations" not in fake.paths()
    (frequency,) = fake.requests_to("/rest/v1/excerpt_frequency")
    assert frequency.url.params["instrument"] == "eq.cello"
    assert frequency.url.params["position_class"] == "eq.principal"


def test_tiers_over_every_region_use_the_plan_thresholds(feed_client, fake):
    fake.frequency = [
        {"instrument": "oboe", "position_class": "other", "region": "uk", "excerpt_id": f"oboe-fixture-{share}",
         "weighted_hits": share, "weighted_lists": 1.0, "n_lists_with_excerpt": 1, "n_lists": 1,
         "earliest_list_date": "2025-01-01", "latest_list_date": "2025-01-01"}
        for share in (0.5, 0.49, 0.2, 0.19)
    ]
    found = feed_client.get("/v1/recommendations?instrument=oboe&position=second").json()["recommendations"]
    assert [(r["share"], r["tier"]) for r in found] == [(0.5, "core"), (0.49, "common"), (0.2, "common"), (0.19, "occasional")]
    assert found[0]["evidence"] == "On 1 of 1 oboe list for second and other chairs across all regions, 2025"


# ------------------------------------------------------------------ evidence wording


@pytest.mark.parametrize(
    ("kwargs", "expected"),
    [
        (dict(instrument="cello", position_class_id="section", region="north-america", listed=7, total=12,
              first_year=2024, last_year=2026), "On 7 of 12 section cello lists in North America, 2024–2026"),
        (dict(instrument="double-bass", position_class_id="assistant-principal", region="europe-german", listed=1,
              total=1, first_year=2025, last_year=2025),
         "On 1 of 1 assistant principal double bass list in German-speaking Europe, 2025"),
        (dict(instrument="e-flat-clarinet", position_class_id="principal", region="asia-pacific", listed=2, total=3),
         "On 2 of 3 principal E♭ clarinet lists in Asia-Pacific"),
        (dict(instrument="horn", position_class_id="other", region="uk", listed=0, total=4),
         "Not on any of the 4 horn lists for second and other chairs we have in the UK — the tier comes from other regions"),
        (dict(instrument="viola", position_class_id="section", region="europe-other", listed=0, total=1),
         "Not on the only section viola list we have in other European countries — the tier comes from other regions"),
        (dict(instrument="keyboard", position_class_id="principal", region="other", listed=0, total=0),
         "No principal piano / celesta lists in other parts of the world yet — the tier comes from other regions"),
        (dict(instrument="tuba", position_class_id="principal", region=None, listed=3, total=5,
              first_year=2026, last_year=2023), "On 3 of 5 principal tuba lists across all regions, 2023–2026"),
    ],
)
def test_evidence_lines(kwargs, expected):
    assert evidence(**kwargs) == expected


# ------------------------------------------------------------------ cache


def test_answers_are_cached_for_ten_minutes(feed_client, fake, clock):
    fake.vacancies = [vacancy_row(1)]
    fake.items = [item_row(1)]
    first = feed_client.get("/v1/auditions?instrument=cello&region=north-america").json()
    calls = len(fake.requests)
    assert calls == 3  # open_auditions, the published check on vacancies, vacancy_items

    fake.vacancies = []  # the database changes; the cached answer stands for ten minutes
    clock.now += 599
    assert feed_client.get("/v1/auditions?instrument=cello&region=north-america").json() == first
    assert len(fake.requests) == calls

    clock.now += 1
    assert feed_client.get("/v1/auditions?instrument=cello&region=north-america").json() == {"auditions": []}
    assert len(fake.requests) == calls + 1


def test_cache_is_per_query(feed_client, fake):
    feed_client.get("/v1/auditions?instrument=cello&region=uk")
    feed_client.get("/v1/auditions?instrument=cello")
    feed_client.get("/v1/auditions?instrument=viola&region=uk")
    feed_client.get("/v1/recommendations?instrument=cello&position=section&region=uk")
    feed_client.get("/v1/recommendations?instrument=cello&position=principal&region=uk")
    before = len(fake.requests)
    assert before == 3 + 2 * 2
    # Same queries again (utility shares the section class) → no new requests.
    feed_client.get("/v1/auditions?instrument=cello&region=uk")
    feed_client.get("/v1/auditions?instrument=cello")
    feed_client.get("/v1/auditions?instrument=viola&region=uk")
    feed_client.get("/v1/recommendations?instrument=cello&position=section&region=uk")
    feed_client.get("/v1/recommendations?instrument=cello&position=utility&region=uk")
    feed_client.get("/v1/recommendations?instrument=cello&position=principal&region=uk")
    assert len(fake.requests) == before


def test_failures_are_not_cached(feed_client, fake):
    fake.fail_status = 500
    assert feed_client.get("/v1/auditions?instrument=cello").status_code == 502
    fake.fail_status = None
    fake.vacancies = [vacancy_row(1)]
    response = feed_client.get("/v1/auditions?instrument=cello")
    assert response.status_code == 200
    assert len(response.json()["auditions"]) == 1


# ------------------------------------------------------------------ Supabase errors


@pytest.mark.parametrize(
    "path",
    ["/v1/auditions?instrument=cello", "/v1/recommendations?instrument=cello&position=section&region=uk",
     "/v1/recommendations?instrument=cello&position=section"],
)
@pytest.mark.parametrize("status", [400, 401, 404, 500, 503])
def test_supabase_error_status_is_502(feed_client, fake, caplog, path, status):
    fake.fail_status = status
    with caplog.at_level(logging.WARNING, logger="auditioner.feed"):
        response = feed_client.get(path)
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_FEED_UPSTREAM}
    assert "SECRET-DETAIL" not in caplog.text  # PostgREST bodies are never logged


@pytest.mark.parametrize("fail_path", ["/rest/v1/vacancies", "/rest/v1/vacancy_items"])
def test_failure_on_a_later_request_is_502(feed_client, fake, fail_path):
    fake.vacancies = [vacancy_row(1)]
    fake.fail_status = 500
    fake.fail_path = fail_path
    response = feed_client.get("/v1/auditions?instrument=cello")
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_FEED_UPSTREAM}


@pytest.mark.parametrize(
    "error", [httpx.ConnectError("no route"), httpx.ReadTimeout("slow"), httpx.RemoteProtocolError("bad")]
)
def test_unreachable_supabase_is_502(feed_client, fake, error):
    fake.raise_error = error
    response = feed_client.get("/v1/recommendations?instrument=cello&position=section&region=uk")
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_FEED_UPSTREAM}


@pytest.mark.parametrize("body", [b"<html>gateway</html>", b'{"auditions": []}', b"[1, 2, 3]", b'"text"'])
def test_unexpected_body_is_502(feed_client, fake, body):
    fake.fail_status = 200
    fake.fail_body = body
    response = feed_client.get("/v1/auditions?instrument=cello")
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_FEED_UPSTREAM}


@pytest.mark.parametrize(
    "error", [httpx.InvalidURL("bad address"), httpx.UnsupportedProtocol("no scheme")]
)
def test_unusable_supabase_address_is_502(feed_client, fake, error):
    fake.raise_error = error
    for path in ("/v1/auditions?instrument=cello", "/v1/recommendations?instrument=cello&position=section&region=uk"):
        response = feed_client.get(path)
        assert response.status_code == 502
        assert response.json() == {"detail": MSG_FEED_UPSTREAM}


def test_the_key_is_never_shown():
    service = FeedService(SUPABASE_URL, SERVICE_KEY)
    assert SERVICE_KEY not in repr(service)
    assert "configured" in repr(service)
    assert "off" in repr(FeedService("", ""))
