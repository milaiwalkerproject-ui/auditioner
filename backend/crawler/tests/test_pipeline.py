"""End to end on a tiny fake web: registry → page → PDF → fake Claude → verify → map → dry-run files."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from crawler.config import Settings
from crawler.fetcher import PoliteFetcher
from crawler.llm import ExtractionClient
from crawler.mapping import Catalogue
from crawler.pipeline import Pipeline
from crawler.policy import HostPolicy
from crawler.registry import Registry
from crawler.store import DryRunWriter

from .conftest import (
    FakeAnthropic,
    FakeClock,
    RouteTable,
    find_lines,
    make_pdf,
    numbered_lines,
)

HOST = "https://www.example-phil.org"
PAGE = f"{HOST}/auditions"
PDF = f"{HOST}/files/section-cello-repertoire.pdf"

PAGE_HTML = """<html><body><nav><a href="/">Home</a></nav><main>
<h1>Auditions</h1>
<p>Section Cello. Application deadline: 15 November 2026.</p>
<p><a href="/files/section-cello-repertoire.pdf">Repertoire list (PDF)</a></p>
<p><a href="https://www.musicalchairs.info/x">Musical Chairs</a></p>
<p><a href="/files/season-brochure.pdf">Season brochure</a></p>
</main></body></html>"""

PDF_LINES = [
    "Example Philharmonic - Section Cello Audition",
    "Application deadline: 15 November 2026",
    "Preliminary round:",
    "Quill: Symphony No. 5, II: mm. 1-106",
    "Reine: Night Fanfare, beginning to 4 before C",
    "Thornquist: Symphony No. 2, IV: mm. 1-44",
]


def fake_claude(kwargs: dict[str, Any]) -> Any:
    """Answers triage for Haiku and a citation-faithful extraction for Opus, built
    from the numbered lines in the request (so ids are real)."""
    if "haiku" in kwargs["model"]:
        return {"hasAuditionContent": True, "pageHasRepertoireList": False, "instruments": ["cello"],
                "documentsToExtract": [PDF], "notes": "section cello audition page"}
    lines = numbered_lines(kwargs)

    def item(composer: str, work: str, movement: str, location: dict[str, Any], *needles: str) -> dict[str, Any]:
        ids = find_lines(lines, *needles)
        return {"sourceLineIds": ids, "rawText": " ".join(lines[i] for i in ids), "round": "Preliminary round",
                "category": "excerpt", "composer": composer, "work": work, "catalogueNumber": "", "movement": movement,
                "part": "", "location": {"type": "unknown", "startText": "", "endText": "", "startBar": 0, "endBar": 0, **location}, "notes": ""}

    return {
        "isAuditionNotice": True,
        "language": "en",
        "vacancies": [{
            "orchestra": "Example Philharmonic", "position": "Section Cello", "instrument": "cello", "chair": "",
            "applicationDeadline": {"value": "2026-11-15", "sourceLineIds": find_lines(lines, "deadline")},
            "auditionDates": [{"value": "2026-12-01", "sourceLineIds": find_lines(lines, "deadline")}],  # not printed → must be dropped
            "listCompleteness": "full",
            "items": [
                item("Quill", "Symphony No. 5", "II", {"type": "measures", "startText": "mm. 1", "endText": "106", "startBar": 1, "endBar": 106}, "Quill"),
                item("Reine", "Night Fanfare", "", {"type": "rehearsal_mark", "startText": "beginning", "endText": "4 before C"}, "Reine"),
                item("Thornquist", "Symphony No. 2", "IV", {"type": "measures", "startText": "mm. 1", "endText": "44", "startBar": 1, "endBar": 44}, "Thornquist"),
                item("Morvane", "Symphony No. 5", "", {"type": "unknown"}, "Thornquist"),  # invented: cites a line without Morvane
            ],
        }],
        "sourceNotes": "",
    }


def build(web: RouteTable, clock: FakeClock, registry: Registry, catalogue: Catalogue, tmp_path: Path, *, llm: bool = True):
    settings = Settings(catalog_dir=tmp_path, out_dir=tmp_path / "out")
    writer = DryRunWriter(settings.out_dir, now=lambda: "2026-10-10T00:00:00+00:00")
    fetcher = PoliteFetcher(policy=HostPolicy(registry.hosts), state=writer, transport=web.transport(), clock=clock, sleep=clock.sleep,
                            now=lambda: datetime(2026, 10, 10, tzinfo=timezone.utc))
    fake = FakeAnthropic(fake_claude)
    client = ExtractionClient(fake) if llm else None
    pipeline = Pipeline(settings=settings, registry=registry, fetcher=fetcher, writer=writer, catalogue=catalogue, llm=client,
                        now=lambda: datetime(2026, 10, 10, tzinfo=timezone.utc))
    return pipeline, writer, fake


def serve(web: RouteTable) -> None:
    web.text(f"{HOST}/robots.txt", "User-agent: *\nDisallow: /private/\n")
    web.html(PAGE, PAGE_HTML, etag='"page-v1"')
    web.pdf(PDF, make_pdf(PDF_LINES), etag='"pdf-v1"')
    web.pdf(f"{HOST}/files/season-brochure.pdf", make_pdf(["Season"]))


def test_first_run_extracts_verifies_maps_and_writes(web, clock, registry, catalogue, tmp_path):
    serve(web)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    report = pipeline.run(orchestra_id="example-phil")
    orchestra = report.orchestras[0]
    assert orchestra.errors == [], orchestra.errors
    assert orchestra.page_changed and orchestra.documents_changed == 1
    assert orchestra.vacancies_written == 1 and orchestra.items_total == 4
    assert orchestra.llm_calls == 2  # one triage (Haiku), one extraction (Opus)
    assert [m for m, _ in [(k["model"], 0) for _, k in fake.calls]] == ["claude-haiku-5-5", "claude-opus-5-5"]

    requested = [str(r.url) for r in web.requests]
    assert requested == [f"{HOST}/robots.txt", PAGE, PDF]  # brochure skipped (no keyword), aggregator never touched
    assert not any("musicalchairs" in u for u in requested)

    files = list((tmp_path / "out" / "vacancies" / "example-phil").glob("*.json"))
    assert len(files) == 1
    vacancy = json.loads(files[0].read_text())
    assert vacancy["position"] == "Section Cello" and vacancy["instrument"] == "cello"
    assert vacancy["applicationDeadline"] == "2026-11-15"
    assert vacancy["auditionDates"] == []  # the invented audition date was dropped
    assert "auditionDate:date_not_in_cited_lines" in vacancy["flags"]
    assert vacancy["sourceUrl"] == PDF and vacancy["reviewStatus"] == "in_review"
    assert vacancy["extraction"]["model"] == "claude-opus-5-5"
    items = {i["composer"]: i for i in vacancy["items"]}
    assert items["Quill"]["verification"]["ok"] and items["Quill"]["mapping"]["bucket"] == "auto"
    assert items["Quill"]["mapping"]["excerptId"] == "cello-fixture-sym-5-mvt2"
    assert items["Reine"]["verification"]["ok"] and items["Reine"]["mapping"]["bucket"] in ("review", "auto")
    assert items["Thornquist"]["verification"]["ok"] and items["Thornquist"]["mapping"]["bucket"] == "new_candidate"
    assert not items["Morvane"]["verification"]["ok"]
    assert "composer_not_in_cited_lines" in items["Morvane"]["verification"]["flags"]
    assert items["Morvane"]["mapping"]["bucket"] != "auto"

    totals = report.to_dict()["totals"]
    assert totals["vacanciesWritten"] == 1 and totals["llmCalls"] == 2 and totals["estimatedCostUsd"] > 0
    assert list((tmp_path / "out" / "runs").glob("*.json"))


def test_second_run_is_conditional_and_calls_no_model(web, clock, registry, catalogue, tmp_path):
    serve(web)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    pipeline.run(orchestra_id="example-phil")
    calls_before = len(fake.calls)

    def not_modified_page(request):
        import httpx
        assert request.headers.get("if-none-match") == '"page-v1"'
        return httpx.Response(304)

    def not_modified_pdf(request):
        import httpx
        assert request.headers.get("if-none-match") == '"pdf-v1"'
        return httpx.Response(304)

    web.add(PAGE, not_modified_page)
    web.add(PDF, not_modified_pdf)
    clock.advance(3600)
    report = pipeline.run(orchestra_id="example-phil")
    orchestra = report.orchestras[0]
    assert orchestra.page_status == "unchanged" and not orchestra.page_changed and orchestra.documents_changed == 0
    assert orchestra.documents_checked == 1  # the known document was re-checked (304) from the stored link list
    assert len(fake.calls) == calls_before
    assert "nothing changed" in " ".join(orchestra.notes)
    assert writer.get_source(PDF).status == "unchanged"
    # Both answered 304, so what was read from them is still listed tonight.
    assert PAGE in writer.touched and PDF in writer.touched
    assert orchestra.sources_unchanged == 2 and orchestra.to_dict()["sourcesUnchanged"] == 2


def test_changed_source_is_not_marked_still_listed(web, clock, registry, catalogue, tmp_path):
    serve(web)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    pipeline.run(orchestra_id="example-phil")
    assert writer.touched == []  # first visit: everything is new
    web.pdf(PDF, make_pdf(PDF_LINES[:4]), etag='"pdf-v2"')
    clock.advance(3600)
    pipeline.run(orchestra_id="example-phil")
    assert PDF not in writer.touched  # the changed list is re-extracted instead


def test_unchanged_content_without_validators_is_still_listed(web, clock, registry, catalogue, tmp_path):
    web.text(f"{HOST}/robots.txt", "User-agent: *\nDisallow: /private/\n")
    web.html(PAGE, PAGE_HTML)  # no ETag / Last-Modified: the server always answers 200
    web.pdf(PDF, make_pdf(PDF_LINES))
    web.pdf(f"{HOST}/files/season-brochure.pdf", make_pdf(["Season"]))
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    pipeline.run(orchestra_id="example-phil")
    clock.advance(3600)
    report = pipeline.run(orchestra_id="example-phil")
    assert not report.orchestras[0].page_changed
    assert PAGE in writer.touched and PDF in writer.touched


def test_changed_document_is_re_extracted_and_replaces_the_snapshot(web, clock, registry, catalogue, tmp_path):
    serve(web)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    pipeline.run(orchestra_id="example-phil")
    first = json.loads(next((tmp_path / "out" / "vacancies" / "example-phil").glob("*.json")).read_text())
    web.pdf(PDF, make_pdf(PDF_LINES[:4]), etag='"pdf-v2"')  # list shortened
    clock.advance(3600)
    report = pipeline.run(orchestra_id="example-phil")
    orchestra = report.orchestras[0]
    assert orchestra.documents_changed == 1 and orchestra.vacancies_written == 1
    second = json.loads(next((tmp_path / "out" / "vacancies" / "example-phil").glob("*.json")).read_text())
    assert second["snapshotHash"] != first["snapshotHash"]
    assert len(second["items"]) < len(first["items"]) or second["items"] != first["items"]


def test_without_an_api_key_changes_are_noticed_but_nothing_is_extracted(web, clock, registry, catalogue, tmp_path):
    serve(web)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path, llm=False)
    report = pipeline.run(orchestra_id="example-phil")
    orchestra = report.orchestras[0]
    assert orchestra.documents_changed == 1 and orchestra.vacancies_written == 0
    assert any("no ANTHROPIC_API_KEY" in note for note in orchestra.notes)
    assert fake.calls == []
    assert not report.llm_enabled


def test_robots_disallow_and_errors_do_not_stop_the_run(web, clock, registry, catalogue, tmp_path):
    web.text(f"{HOST}/robots.txt", "User-agent: AuditionerBot\nDisallow: /\n")
    web.html(PAGE, PAGE_HTML)
    web.text("https://jugend.example.de/robots.txt", "", status=404)
    web.text("https://jugend.example.de/", "", status=500)
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    report = pipeline.run()
    assert [o.orchestra_id for o in report.orchestras] == ["example-phil", "example-youth"]
    phil, youth = report.orchestras
    assert "robots.txt" in phil.page_status
    assert youth.errors and "server error" in youth.errors[0]
    assert fake.calls == []
    assert report.fatal is None


def test_unknown_orchestra_id_is_reported(web, clock, registry, catalogue, tmp_path):
    pipeline, _, _ = build(web, clock, registry, catalogue, tmp_path)
    report = pipeline.run(orchestra_id="nobody")
    assert report.fatal and "nobody" in report.fatal


def test_extract_file_runs_the_same_checks_on_a_local_pdf(web, clock, registry, catalogue, tmp_path):
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    path = tmp_path / "uploaded-list.pdf"
    path.write_bytes(make_pdf(PDF_LINES))
    records, report = pipeline.extract_file(path, orchestra=registry.get("example-phil"), instrument_hint="cello")
    assert len(records) == 1 and report.errors == []
    assert records[0].source_url == "file:uploaded-list.pdf"
    assert records[0].items[0]["mapping"]["bucket"] == "auto"
    _, kwargs = fake.calls[-1]
    assert "the user says this list is for: cello" in json.dumps(kwargs["messages"])
    assert kwargs["messages"][0]["content"][0]["type"] == "document"  # the PDF went along


def test_start_url_that_is_itself_a_pdf_is_extracted_once_and_then_tracked(web, clock, registry, catalogue, tmp_path):
    web.text(f"{HOST}/robots.txt", "", status=404)
    web.pdf(PAGE, make_pdf(PDF_LINES), etag='"direct-v1"')  # the registry points straight at the list
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    first = pipeline.run(orchestra_id="example-phil").orchestras[0]
    assert first.errors == [] and first.vacancies_written == 1 and first.documents_changed == 1
    assert not first.page_changed  # the document's own change detection decides
    calls_before = len(fake.calls)

    def not_modified(request):
        import httpx
        assert request.headers.get("if-none-match") == '"direct-v1"'
        return httpx.Response(304)

    web.add(PAGE, not_modified)
    clock.advance(3600)
    second = pipeline.run(orchestra_id="example-phil").orchestras[0]
    assert second.vacancies_written == 0 and second.documents_changed == 0
    assert len(fake.calls) == calls_before
    assert "nothing changed" in " ".join(second.notes)


def test_contact_details_are_stripped_before_anything_is_stored(web, clock, registry, catalogue, tmp_path):
    from crawler.documents import text_document
    from crawler.llm import LLMResult
    from crawler.pipeline import OrchestraReport

    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    orchestra = registry.get("example-phil")
    source = text_document(
        "Section Cello audition\n"
        "Quill: Symphony No. 5, II: mm. 1-106\n"
        "Questions: auditions@example-phil.org or +1 (555) 010-2030"
    )
    data = {
        "isAuditionNotice": True, "language": "en", "sourceNotes": "Contact jane.doe@example-phil.org for the list",
        "vacancies": [{
            "orchestra": "Example Philharmonic", "position": "Section Cello (write to auditions@example-phil.org)",
            "instrument": "cello", "chair": "",
            "applicationDeadline": {"value": "", "sourceLineIds": []}, "auditionDates": [], "listCompleteness": "full",
            "items": [{
                "sourceLineIds": ["L0002", "L0003"],
                "rawText": "Quill: Symphony No. 5, II: mm. 1-106 Questions: auditions@example-phil.org or +1 (555) 010-2030",
                "round": "", "category": "excerpt", "composer": "Quill", "work": "Symphony No. 5", "catalogueNumber": "Op. 12",
                "movement": "II", "part": "",
                "location": {"type": "measures", "startText": "mm. 1", "endText": "106", "startBar": 1, "endBar": 106},
                "notes": "Tel. 555-010-2030",
            }],
        }],
    }
    report = OrchestraReport(orchestra_id=orchestra.id, name=orchestra.name)
    records = pipeline.build_records(orchestra, "https://www.example-phil.org/list.html", source, "html",
                                     LLMResult(ok=True, model="claude-opus-5-5", data=data), report)
    record = records[0]
    dumped = json.dumps(record.to_dict())
    assert "@" not in dumped and "010-2030" not in dumped and "555" not in dumped, dumped
    assert "[email removed]" in record.position and "contact_details_removed" in record.flags
    item = record.items[0]
    assert item["rawText"].startswith("Quill: Symphony No. 5, II: mm. 1-106")  # the facts survive
    assert item["location"]["startBar"] == 1 and item["location"]["endBar"] == 106 and item["catalogueNumber"] == "Op. 12"
    assert item["verification"]["ok"]  # verification ran on the source lines, not on the redacted text
    assert record.extraction["sourceNotes"] == "Contact [email removed] for the list"
    assert report.contacts_redacted >= 4 and report.to_dict()["contactsRedacted"] == report.contacts_redacted


def test_a_long_crawl_delay_is_honoured_by_reading_fewer_documents(web, clock, registry, catalogue, tmp_path):
    web.text(f"{HOST}/robots.txt", "User-agent: *\nCrawl-delay: 500\n")
    html = "<html><body><main><h1>Auditions</h1>" + "".join(
        f'<p><a href="/files/repertoire-{n}.pdf">Repertoire list {n}</a></p>' for n in range(3)
    ) + "</main></body></html>"
    web.html(PAGE, html)
    for n in range(3):
        web.pdf(f"{HOST}/files/repertoire-{n}.pdf", make_pdf(PDF_LINES))
    pipeline, writer, fake = build(web, clock, registry, catalogue, tmp_path)
    report = pipeline.run(orchestra_id="example-phil").orchestras[0]
    requested = [str(r.url) for r in web.requests]
    assert requested[:2] == [f"{HOST}/robots.txt", PAGE]
    assert len([u for u in requested if u.endswith(".pdf")]) == 1  # 1200 s budget / 500 s delay → one more request
    assert clock.sleeps[-1] >= 500  # and that request waited the full delay
    assert any("crawl delay" in note for note in report.notes)
