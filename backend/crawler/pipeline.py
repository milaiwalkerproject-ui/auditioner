"""The nightly job, step by step, for one orchestra at a time:

registry entry → fetch its audition page (conditional GET) → notice changes →
collect repertoire documents it links to → triage (Haiku) → extract (Opus) →
verify every item against its cited lines → map to the catalogue → write to the
review queue.

Nothing is published here: every vacancy lands as `in_review` (PLAN F3).
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import __version__
from .config import Settings
from .documents import ExtractedText, append_lines, extract_document, text_document
from .fetcher import FetchResult, PoliteFetcher
from .llm import ExtractionClient, LLMFatal, LLMResult
from .mapping import Catalogue, map_item
from .pages import (
    Link,
    bytes_hash,
    content_hash,
    discover_links,
    main_text,
    parse_job_postings,
)
from .policy import is_document_url
from .redact import redact_text, redact_value
from .registry import Orchestra, Registry, select
from .schema import coerce_extraction
from .store import VacancyRecord, Writer
from .verify import verify_vacancy

log = logging.getLogger("auditioner.crawler.pipeline")

STRONG_DOCUMENT_HINTS = ("repertoire", "repertory", "excerpt", "probespiel", "rep-list", "replist", "liste", "repertorio")


@dataclass
class OrchestraReport:
    orchestra_id: str
    name: str
    start_url: str | None = None
    page_status: str = ""
    page_changed: bool = False
    pages_checked: int = 0
    documents_checked: int = 0
    documents_changed: int = 0
    sources_unchanged: int = 0
    extracted: int = 0
    vacancies_written: int = 0
    items_total: int = 0
    items_verified: int = 0
    items_auto_mapped: int = 0
    llm_calls: int = 0
    estimated_cost_usd: float = 0.0
    contacts_redacted: int = 0
    notes: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "orchestraId": self.orchestra_id,
            "name": self.name,
            "startUrl": self.start_url,
            "pageStatus": self.page_status,
            "pageChanged": self.page_changed,
            "pagesChecked": self.pages_checked,
            "documentsChecked": self.documents_checked,
            "documentsChanged": self.documents_changed,
            "sourcesUnchanged": self.sources_unchanged,
            "extracted": self.extracted,
            "vacanciesWritten": self.vacancies_written,
            "itemsTotal": self.items_total,
            "itemsVerified": self.items_verified,
            "itemsAutoMapped": self.items_auto_mapped,
            "llmCalls": self.llm_calls,
            "estimatedCostUsd": round(self.estimated_cost_usd, 4),
            "contactsRedacted": self.contacts_redacted,
            "notes": list(self.notes),
            "errors": list(self.errors),
        }


@dataclass
class RunReport:
    started_at: str
    finished_at: str = ""
    dry_run: bool = True
    llm_enabled: bool = False
    orchestras: list[OrchestraReport] = field(default_factory=list)
    fatal: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "crawlerVersion": __version__,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "dryRun": self.dry_run,
            "llmEnabled": self.llm_enabled,
            "fatal": self.fatal,
            "totals": {
                "orchestras": len(self.orchestras),
                "pagesChecked": sum(o.pages_checked for o in self.orchestras),
                "documentsChecked": sum(o.documents_checked for o in self.orchestras),
                "changed": sum(1 for o in self.orchestras if o.page_changed or o.documents_changed),
                "vacanciesWritten": sum(o.vacancies_written for o in self.orchestras),
                "itemsTotal": sum(o.items_total for o in self.orchestras),
                "llmCalls": sum(o.llm_calls for o in self.orchestras),
                "estimatedCostUsd": round(sum(o.estimated_cost_usd for o in self.orchestras), 4),
                "contactsRedacted": sum(o.contacts_redacted for o in self.orchestras),
                "errors": sum(len(o.errors) for o in self.orchestras),
            },
            "orchestras": [o.to_dict() for o in self.orchestras],
        }


@dataclass
class _Source:
    url: str
    kind: str  # page | pdf | docx | doc
    text: ExtractedText
    raw: bytes
    changed: bool
    strong: bool = False
    link_text: str = ""


class Pipeline:
    def __init__(
        self,
        *,
        settings: Settings,
        registry: Registry,
        fetcher: PoliteFetcher,
        writer: Writer,
        catalogue: Catalogue,
        llm: ExtractionClient | None = None,
        dry_run: bool = True,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.settings = settings
        self.registry = registry
        self.fetcher = fetcher
        self.writer = writer
        self.catalogue = catalogue
        self.llm = llm
        self.dry_run = dry_run
        self._now = now or (lambda: datetime.now(timezone.utc))

    # ------------------------------------------------------------------ run

    def run(self, *, orchestra_id: str | None = None, limit: int | None = None) -> RunReport:
        report = RunReport(started_at=self._now().isoformat(), dry_run=self.dry_run, llm_enabled=self.llm is not None)
        chosen = select(self.registry, orchestra_id=orchestra_id, limit=limit)
        if orchestra_id and not chosen:
            report.fatal = f"orchestra '{orchestra_id}' is not in the registry (or has no address)"
        workers = max(1, self.settings.concurrency)
        try:
            if workers == 1 or len(chosen) <= 1:
                for orchestra in chosen:
                    report.orchestras.append(self.process(orchestra))
            else:
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    report.orchestras.extend(pool.map(self.process, chosen))
        except LLMFatal as exc:
            report.fatal = str(exc)
            log.error("stopping the run: %s", exc)
        report.finished_at = self._now().isoformat()
        try:
            self.writer.finish(report.to_dict())
        except Exception as exc:  # the summary must never hide the real result
            log.warning("could not store the run summary: %s", exc)
        return report

    # ------------------------------------------------------------------ one orchestra

    def process(self, orchestra: Orchestra) -> OrchestraReport:
        report = OrchestraReport(orchestra_id=orchestra.id, name=orchestra.name, start_url=orchestra.start_url)
        try:
            self.writer.write_orchestra(orchestra)
        except Exception as exc:
            report.errors.append(f"could not store orchestra: {exc}")
        if not orchestra.start_url:
            report.notes.append("no auditionsUrl or homepageUrl in the registry")
            return report
        try:
            self._process(orchestra, report)
        except LLMFatal:
            raise
        except Exception as exc:  # one orchestra must never stop the nightly run
            log.exception("%s: unexpected failure", orchestra.id)
            report.errors.append(f"unexpected failure: {exc.__class__.__name__}: {exc}")
        return report

    def _fetch_page(self, url: str, orchestra: Orchestra, report: OrchestraReport, *, linked_from: str | None = None
                    ) -> tuple[FetchResult, str, list[Link], list[str], bool]:
        """Returns (result, page text, links, job-posting lines, changed?)."""
        result = self.fetcher.fetch(url, kind="page", orchestra_id=orchestra.id, linked_from=linked_from)
        report.pages_checked += 1
        previous = self.writer.get_source(url)
        if result.unchanged:
            self.fetcher.record(result, orchestra_id=orchestra.id, kind="page")
            self._still_listed(report, url, result.final_url)
            links = [Link(**entry) for entry in (previous.extra.get("links") or [])] if previous else []
            return result, "", links, [], False
        if not result.ok:
            self.fetcher.record(result, orchestra_id=orchestra.id, kind="page", note=result.error)
            return result, "", [], [], False
        if "html" not in result.content_type and not result.body.lstrip()[:200].lower().startswith((b"<!doctype", b"<html")):
            if is_document_url(result.final_url) or result.content_type == "application/pdf":
                # The "page" is itself a document (some orchestras link straight to a PDF).
                return result, "", [Link(url=result.final_url, text="audition page", kind="document", strong=True)], [], False
        text = main_text(result.body)
        new_hash = content_hash(text)
        changed = previous is None or previous.content_hash != new_hash
        links = discover_links(result.body, result.final_url)
        postings = parse_job_postings(result.body)
        posting_lines = [line for posting in postings for line in posting.to_lines()]
        record = self.fetcher.record(result, orchestra_id=orchestra.id, kind="page", content_hash=new_hash)
        kept = links[: self.settings.max_documents_per_orchestra + self.settings.max_subpages_per_orchestra]
        record.extra["links"] = [{**link.__dict__, "text": redact_text(link.text)[0]} for link in kept]
        self.writer.put_source(record)
        if not changed:
            self._still_listed(report, url, result.final_url)
        return result, text, links, posting_lines, changed

    def _fetch_document(self, link: Link, orchestra: Orchestra, page_url: str, report: OrchestraReport) -> _Source | None:
        result = self.fetcher.fetch(link.url, kind="document", linked_from=page_url, orchestra_id=orchestra.id)
        report.documents_checked += 1
        previous = self.writer.get_source(link.url)
        if result.unchanged:
            self.fetcher.record(result, orchestra_id=orchestra.id, kind="document")
            self._still_listed(report, link.url, result.final_url)
            return None
        if not result.ok:
            self.fetcher.record(result, orchestra_id=orchestra.id, kind="document", note=result.error)
            if not result.skipped:
                report.errors.append(f"{link.url}: {result.error}")
            else:
                report.notes.append(f"{link.url}: {result.error}")
            return None
        raw_hash = bytes_hash(result.body)
        text = extract_document(result.body, url=result.final_url, content_type=result.content_type)
        for note in text.notes:
            report.notes.append(f"{link.url}: {note}")
        text_hash = text.text_hash() if text.lines else None
        changed = previous is None or previous.content_hash != raw_hash
        if not changed and previous is not None and text_hash and previous.text_hash and previous.text_hash != text_hash:
            changed = True
        self.fetcher.record(result, orchestra_id=orchestra.id, kind="document", content_hash=raw_hash, text_hash=text_hash,
                            note="; ".join(text.notes) or None)
        if not changed:
            self._still_listed(report, link.url, result.final_url)
        if text.skipped:
            return None
        if changed:
            report.documents_changed += 1
        return _Source(url=result.final_url, kind=text.kind, text=text, raw=result.body, changed=changed,
                       strong=link.strong or any(h in link.url.lower() for h in STRONG_DOCUMENT_HINTS), link_text=link.text)

    def _still_listed(self, report: OrchestraReport, *urls: str) -> None:
        """The source answered and is unchanged since the last visit, so whatever we read
        from it is still on the orchestra's site tonight: move `last_seen_at` on, or an
        audition with no deadline would drop out of the feed 60 days after it was first read
        and "last checked" in the app would show an old date. A changed source is not
        touched here; its vacancies are rewritten (or left to expire) by extraction."""
        report.sources_unchanged += 1
        for url in dict.fromkeys(u for u in urls if u):
            try:
                self.writer.touch_source(url)
            except Exception as exc:  # a missed touch must not stop the orchestra
                report.errors.append(f"could not mark {url} as still listed: {exc}")

    def _process(self, orchestra: Orchestra, report: OrchestraReport) -> None:
        start_url = orchestra.start_url or ""
        result, page_text, links, posting_lines, page_changed = self._fetch_page(start_url, orchestra, report)
        report.page_status = "unchanged" if result.unchanged else ("ok" if result.ok else (result.error or "error"))
        report.page_changed = page_changed
        if not result.ok and not result.unchanged:
            report.errors.append(f"{start_url}: {result.error}") if not result.skipped else report.notes.append(f"{start_url}: {result.error}")
            return

        max_subpages, max_documents = self._request_budget(start_url, report)

        # Sub-pages on the same host that look like audition pages (one level deep).
        document_links: list[Link] = [link for link in links if link.kind == "document"]
        sub_pages = [link for link in links if link.kind == "page"][:max_subpages]
        sub_texts: list[tuple[str, str, list[str]]] = []
        for sub in sub_pages:
            sub_result, sub_text, sub_links, sub_postings, sub_changed = self._fetch_page(sub.url, orchestra, report, linked_from=result.final_url)
            if sub_result.ok and sub_changed and sub_text:
                sub_texts.append((sub.url, sub_text, sub_postings))
            for link in sub_links:
                if link.kind == "document" and link.url not in {d.url for d in document_links}:
                    document_links.append(link)

        # Documents (pdf/doc/docx) the orchestra links to.
        sources: list[_Source] = []
        for link in document_links[:max_documents]:
            source = self._fetch_document(link, orchestra, result.final_url, report)
            if source is not None:
                sources.append(source)

        changed_docs = [s for s in sources if s.changed]
        if not page_changed and not changed_docs and not sub_texts:
            report.notes.append("nothing changed since the last visit")
            return

        if self.llm is None:
            names = ", ".join(s.url for s in changed_docs) or "(no documents)"
            report.notes.append(f"changes noticed but extraction skipped: no ANTHROPIC_API_KEY. Changed documents: {names}")
            return

        # Triage with the cheap model: is this an audition page, and which documents matter?
        to_extract: list[_Source] = []
        page_sources: list[tuple[str, str, list[str]]] = []
        if page_text or sub_texts:
            combined_text = page_text
            for sub_url, sub_text, _ in sub_texts:
                combined_text += f"\n\n--- sub-page {sub_url} ---\n{sub_text}"
            link_pairs = [(s.url, s.link_text) for s in sources]
            triage = self.llm.triage(orchestra_name=orchestra.name, page_url=result.final_url,
                                     page_text=combined_text, links=link_pairs)
            report.llm_calls += 1
            report.estimated_cost_usd += triage.estimated_cost_usd
            if triage.ok and triage.data:
                wanted = set(triage.data["documentsToExtract"])
                triage_note, redacted = redact_text(triage.data["notes"] or "ok")
                report.contacts_redacted += redacted
                report.notes.append(f"triage: {triage_note}")
                for source in sources:
                    if source.changed and (source.url in wanted or source.strong):
                        to_extract.append(source)
                if triage.data["pageHasRepertoireList"]:
                    if page_changed and page_text:
                        page_sources.append((result.final_url, page_text, posting_lines))
                    page_sources.extend(sub_texts)
                elif not triage.data["hasAuditionContent"] and not to_extract:
                    report.notes.append("triage: no audition content on this page")
            else:
                report.errors.append(f"triage failed: {triage.error}")
                to_extract = [s for s in changed_docs if s.strong]
        else:
            to_extract = [s for s in changed_docs if s.strong] or changed_docs

        for source in to_extract:
            self._extract_and_write(orchestra, source.url, source.text, source.raw if source.kind == "pdf" else None,
                                    source.kind, report)
        for url, text, postings in page_sources:
            doc = text_document(text, kind="html")
            if postings:
                append_lines(doc, postings)
            self._extract_and_write(orchestra, url, doc, None, "html", report)

    def _request_budget(self, url: str, report: OrchestraReport) -> tuple[int, int]:
        """(further pages, documents) this host gets tonight. A long Crawl-delay in
        robots.txt is honoured in full; what gives is the number of requests, so one
        site cannot hold the nightly job for hours."""
        max_subpages = self.settings.max_subpages_per_orchestra
        max_documents = self.settings.max_documents_per_orchestra
        gap = self.fetcher.host_state(url).gap
        budget = self.settings.per_host_time_budget_seconds
        if gap <= 0 or budget <= 0:
            return max_subpages, max_documents
        allowed = max(0, int(budget // gap) - 1)  # minus the page already read
        if allowed >= max_subpages + max_documents:
            return max_subpages, max_documents
        max_subpages = min(max_subpages, allowed // 3)
        max_documents = min(max_documents, allowed - max_subpages)
        report.notes.append(
            f"robots.txt asks for a {gap:.0f} s crawl delay — reading at most {max_documents} documents "
            f"and {max_subpages} further pages tonight"
        )
        return max_subpages, max_documents

    # ------------------------------------------------------------------ extraction

    def _extract_and_write(self, orchestra: Orchestra, source_url: str, source: ExtractedText, pdf_bytes: bytes | None,
                           source_kind: str, report: OrchestraReport, *, hints: list[str] | None = None) -> list[VacancyRecord]:
        records = self.extract_source(orchestra, source_url, source, pdf_bytes, source_kind, report, hints=hints)
        for record in records:
            try:
                self.writer.write_vacancy(record)
                report.vacancies_written += 1
            except Exception as exc:
                report.errors.append(f"could not store vacancy '{record.position}': {exc}")
        return records

    def extract_source(self, orchestra: Orchestra, source_url: str, source: ExtractedText, pdf_bytes: bytes | None,
                       source_kind: str, report: OrchestraReport, *, hints: list[str] | None = None) -> list[VacancyRecord]:
        if self.llm is None:
            report.notes.append("extraction skipped: no ANTHROPIC_API_KEY")
            return []
        registry_hints = [f"registry notes: {orchestra.notes}"] if orchestra.notes else []
        result: LLMResult = self.llm.extract(
            orchestra_name=orchestra.name, orchestra_country=orchestra.country, source_url=source_url,
            source=source, pdf_bytes=pdf_bytes, hints=registry_hints + (hints or []),
        )
        report.llm_calls += 1
        report.estimated_cost_usd += result.estimated_cost_usd
        if not result.ok or result.data is None:
            report.errors.append(f"{source_url}: extraction failed: {result.error}")
            return []
        report.extracted += 1
        return self.build_records(orchestra, source_url, source, source_kind, result, report)

    def build_records(self, orchestra: Orchestra, source_url: str, source: ExtractedText, source_kind: str,
                      result: LLMResult, report: OrchestraReport) -> list[VacancyRecord]:
        data = coerce_extraction(result.data)
        lines = source.by_id
        snapshot = source.text_hash() if source.lines else bytes_hash(source_url.encode("utf-8"))
        records: list[VacancyRecord] = []
        if not data["isAuditionNotice"] and not data["vacancies"]:
            report.notes.append(f"{source_url}: not an audition notice ({data['sourceNotes'] or 'no details'})")
            return records
        for vacancy in data["vacancies"]:
            cleaned, verifications, flags = verify_vacancy(vacancy, lines)
            instrument = cleaned["instrument"]
            items: list[dict[str, Any]] = []
            for item, verification in zip(cleaned["items"], verifications, strict=True):
                mapping = map_item(item, verification, self.catalogue, instrument)
                enriched = dict(item)
                if "bars_invalid" in verification.flags:
                    # Never store a bar range that does not parse (the DB refuses it too);
                    # keep what the model said as text for the reviewer.
                    location = dict(enriched.get("location") or {})
                    location["rejectedBars"] = f"{location.get('startBar', 0)}-{location.get('endBar', 0)}"
                    location.update({"type": "unknown", "startBar": 0, "endBar": 0})
                    enriched["location"] = location
                enriched["verification"] = verification.to_dict()
                enriched["mapping"] = mapping.to_dict()
                items.append(enriched)
                report.items_total += 1
                if verification.ok:
                    report.items_verified += 1
                if mapping.bucket == "auto":
                    report.items_auto_mapped += 1
            if not source.has_text:
                flags.append("source_has_no_text_layer")
            # Contact details never reach the store (docs/BOT.md): strip them from every
            # text field, the verbatim source lines of each item included. This runs after
            # verification, which checked the facts against the real source lines.
            items, redacted = redact_value(items)
            position, n = redact_text(cleaned["position"])
            redacted += n
            chair, n = redact_text(cleaned["chair"])
            redacted += n
            orchestra_name, n = redact_text(cleaned["orchestra"])
            redacted += n
            source_notes, n = redact_text(data["sourceNotes"])
            redacted += n
            if redacted:
                flags.append("contact_details_removed")
                report.contacts_redacted += redacted
            records.append(
                VacancyRecord(
                    orchestra_id=orchestra.id,
                    position=position,
                    instrument=instrument,
                    chair=chair,
                    application_deadline=cleaned["applicationDeadline"]["value"],
                    audition_dates=cleaned["auditionDates"],
                    list_completeness=cleaned["listCompleteness"],
                    source_url=source_url,
                    source_kind=source_kind,
                    snapshot_hash=snapshot,
                    items=items,
                    extraction={
                        "model": result.model,
                        "extractedAt": self._now().isoformat(),
                        "language": data["language"],
                        "sourceNotes": source_notes,
                        "requestId": result.request_id,
                        "usage": result.usage.to_dict(),
                        "estimatedCostUsd": round(result.estimated_cost_usd, 4),
                        "documentNotes": list(source.notes),
                        "crawlerVersion": __version__,
                    },
                    flags=flags,
                    orchestra_name_in_source=orchestra_name,
                )
            )
        return records

    # ------------------------------------------------------------------ files

    def extract_file(self, path: Path | str, *, orchestra: Orchestra | None = None,
                     instrument_hint: str | None = None) -> tuple[list[VacancyRecord], OrchestraReport]:
        """Extract a list from a local file (a user-uploaded list, a saved PDF)."""
        path = Path(path)
        data = path.read_bytes()
        orchestra = orchestra or Orchestra(
            id="unknown-orchestra", name="(unknown orchestra)", country="", region="other", type="professional",
            source="https://example.invalid/", as_of=self._now().date().isoformat(),
        )
        report = OrchestraReport(orchestra_id=orchestra.id, name=orchestra.name, start_url=None)
        suffix = path.suffix.lower()
        if suffix in (".pdf", ".doc", ".docx"):
            source = extract_document(data, url=path.name)
            kind = source.kind
        elif suffix in (".html", ".htm"):
            source = text_document(main_text(data), kind="html")
            kind = "html"
        else:
            source = text_document(data.decode("utf-8", "replace"), kind="text")
            kind = "text"
        for note in source.notes:
            report.notes.append(f"{path.name}: {note}")
        if source.skipped:
            report.errors.append(f"{path.name}: could not read this file type")
            return [], report
        hints = [f"the user says this list is for: {instrument_hint}"] if instrument_hint else []
        source_url = f"file:{path.name}"
        records = self._extract_and_write(orchestra, source_url, source, data if kind == "pdf" else None, kind, report, hints=hints)
        return records, report
