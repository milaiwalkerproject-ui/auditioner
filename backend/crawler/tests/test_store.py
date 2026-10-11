from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from crawler.registry import Registry
from crawler.state import SourceRecord
from crawler.store import DryRunWriter, StoreError, SupabaseWriter, VacancyRecord

KEY = "service-role-secret"
URL = "https://abc.supabase.co"


def record(**overrides) -> VacancyRecord:
    base = dict(
        orchestra_id="example-phil", position="Section Cello", instrument="cello", chair="",
        application_deadline="2026-11-15", audition_dates=[{"value": "2026-12-01", "sourceLineIds": ["L0002"]}],
        list_completeness="full", source_url="https://www.example-phil.org/files/list.pdf", source_kind="pdf",
        snapshot_hash="hash-1",
        items=[{"rawText": "Beethoven: Symphony No. 5, II, mm. 1-106", "round": "", "category": "excerpt", "composer": "Beethoven",
                "work": "Symphony No. 5", "catalogueNumber": "Op. 67", "movement": "II", "part": "", "notes": "",
                "location": {"type": "measures", "startBar": 1, "endBar": 106, "startText": "", "endText": ""},
                "sourceLineIds": ["L0003"], "verification": {"ok": True, "flags": []},
                "mapping": {"excerptId": "cello-fixture-sym-5-mvt2", "confidence": 0.95, "bucket": "auto"}}],
        extraction={"model": "claude-opus-5-5"}, flags=[],
    )
    base.update(overrides)
    return VacancyRecord(**base)


class FakeSupabase:
    """Enough of PostgREST to check the request shape."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.vacancies: dict[str, dict] = {}
        self.items: list[dict] = []
        self.sources: dict[str, dict] = {}

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        params = dict(request.url.params)
        body = json.loads(request.content) if request.content else None
        if path.endswith("/vacancies") and request.method == "GET":
            key = params["natural_key"].removeprefix("eq.")
            row = self.vacancies.get(key)
            return httpx.Response(200, json=[row] if row else [])
        if path.endswith("/vacancies") and request.method == "POST":
            row = dict(body[0])
            existing = self.vacancies.get(row["natural_key"]) or {}
            merged = {**existing, **row}
            merged.setdefault("id", f"uuid-{len(self.vacancies) + 1}")
            self.vacancies[row["natural_key"]] = merged
            return httpx.Response(201, json=[merged])
        if path.endswith("/vacancies") and request.method == "PATCH":
            for row in self.vacancies.values():
                if f"eq.{row['id']}" == params["id"]:
                    row.update(body)
            return httpx.Response(204)
        if path.endswith("/vacancy_items") and request.method == "DELETE":
            self.items = [i for i in self.items if f"eq.{i['vacancy_id']}" != params["vacancy_id"]]
            return httpx.Response(204)
        if path.endswith("/vacancy_items") and request.method == "POST":
            self.items.extend(body)
            return httpx.Response(201)
        if path.endswith("/audition_sources") and request.method == "GET":
            url = params["url"].removeprefix("eq.")
            row = self.sources.get(url)
            return httpx.Response(200, json=[row] if row else [])
        if path.endswith("/audition_sources") and request.method == "POST":
            self.sources[body[0]["url"]] = body[0]
            return httpx.Response(201, json=body)
        if path.endswith("/orchestras") and request.method == "POST":
            return httpx.Response(201, json=body)
        if path.endswith("/crawl_runs"):
            return httpx.Response(201)
        return httpx.Response(500, json={"message": "unexpected"})


@pytest.fixture
def supabase() -> tuple[SupabaseWriter, FakeSupabase]:
    fake = FakeSupabase()
    return SupabaseWriter(URL, KEY, transport=httpx.MockTransport(fake.handle), now=lambda: "2026-10-10T00:00:00+00:00"), fake


def test_requests_carry_service_key_and_upsert_headers(supabase):
    writer, fake = supabase
    writer.write_vacancy(record())
    posts = [r for r in fake.requests if r.method == "POST" and r.url.path.endswith("/vacancies")]
    assert posts, "vacancy upsert expected"
    post = posts[0]
    assert post.headers["apikey"] == KEY
    assert post.headers["authorization"] == f"Bearer {KEY}"
    assert post.headers["prefer"] == "resolution=merge-duplicates,return=representation"
    assert post.url.params["on_conflict"] == "natural_key"
    assert str(post.url).startswith(f"{URL}/rest/v1/vacancies")
    row = json.loads(post.content)[0]
    assert row["review_status"] == "in_review"
    assert row["application_deadline"] == "2026-11-15"
    assert row["first_seen_at"] == "2026-10-10T00:00:00+00:00"
    assert row["natural_key"] == record().natural_key
    items = [r for r in fake.requests if r.method == "POST" and r.url.path.endswith("/vacancy_items")]
    item_row = json.loads(items[0].content)[0]
    assert item_row["excerpt_id"] == "cello-fixture-sym-5-mvt2" and item_row["match_confidence"] == 0.95
    assert item_row["review_status"] == "in_review" and item_row["ordinal"] == 1
    assert item_row["vacancy_id"] == "uuid-1"


def test_unchanged_snapshot_only_touches_last_seen(supabase):
    writer, fake = supabase
    writer.write_vacancy(record())
    before = len(fake.items)
    writer.write_vacancy(record())
    methods = [(r.method, r.url.path.rsplit("/", 1)[-1]) for r in fake.requests[-2:]]
    assert methods == [("GET", "vacancies"), ("PATCH", "vacancies")]
    assert len(fake.items) == before
    assert fake.vacancies[record().natural_key]["last_seen_at"] == "2026-10-10T00:00:00+00:00"


def test_changed_snapshot_replaces_items_and_reopens_review(supabase):
    writer, fake = supabase
    writer.write_vacancy(record())
    fake.vacancies[record().natural_key]["review_status"] = "published"
    writer.write_vacancy(record(snapshot_hash="hash-2", items=[]))
    row = fake.vacancies[record().natural_key]
    assert row["snapshot_hash"] == "hash-2" and row["review_status"] == "in_review"
    assert "first_seen_at" not in json.loads([r for r in fake.requests if r.method == "POST" and r.url.path.endswith("/vacancies")][-1].content)[0]
    assert any(r.method == "DELETE" for r in fake.requests)
    assert fake.items == []


def test_source_state_round_trips(supabase):
    writer, fake = supabase
    assert writer.get_source("https://x.example/a") is None
    writer.put_source(SourceRecord(url="https://x.example/a", etag='"v1"', status="ok", extra={"links": []}))
    post = [r for r in fake.requests if r.url.path.endswith("/audition_sources") and r.method == "POST"][0]
    assert post.url.params["on_conflict"] == "url"
    stored = writer.get_source("https://x.example/a")
    assert stored.etag == '"v1"' and stored.extra == {"links": []}


def test_errors_are_plain_without_secrets(supabase):
    writer, fake = supabase
    fake.handle = lambda request: httpx.Response(401, json={"message": "Invalid API key"})
    writer._client = httpx.Client(base_url=f"{URL}/rest/v1", transport=httpx.MockTransport(fake.handle), headers={"apikey": KEY})
    with pytest.raises(StoreError) as excinfo:
        writer.write_orchestra(Registry().get("x") or _orchestra())
    assert "401" in str(excinfo.value) and KEY not in str(excinfo.value)
    with pytest.raises(StoreError):
        SupabaseWriter("", "")


def _orchestra():
    from crawler.registry import Orchestra

    return Orchestra(id="x", name="X", country="US", region="other", type="professional", source="https://x.example/", as_of="2026-01-01")


def test_dry_run_writer_files_and_state(tmp_path: Path):
    writer = DryRunWriter(tmp_path / "out", now=lambda: "2026-10-10T00:00:00+00:00")
    writer.write_orchestra(_orchestra())
    key = writer.write_vacancy(record())
    assert (tmp_path / "out" / "orchestras" / "x.json").exists()
    written = json.loads((tmp_path / "out" / "vacancies" / "example-phil" / f"{key}.json").read_text())
    assert written["reviewStatus"] == "in_review" and written["items"][0]["mapping"]["bucket"] == "auto"
    assert written["sourceUrl"] == "https://www.example-phil.org/files/list.pdf"
    writer.put_source(SourceRecord(url="https://a.example/", etag="e", extra={"links": [{"url": "u", "text": "t", "kind": "document", "strong": True}]}))
    again = DryRunWriter(tmp_path / "out")
    restored = again.get_source("https://a.example/")
    assert restored.etag == "e" and restored.extra["links"][0]["url"] == "u"
    writer.finish({"ok": True})
    assert list((tmp_path / "out" / "runs").glob("*.json"))
