"""Claude calls: a cheap triage pass (Haiku) and the careful extraction pass (Opus).

Follows the claude-api skill for the Python SDK 1.x:
* structured outputs via `output_config.format` with a fixed JSON schema (schema.py);
* the fixed instructions sit in a `system` text block with `cache_control`, so every
  list after the first reads them from the prompt cache;
* the PDF itself goes along as a base64 `document` block, before the numbered text;
* thinking is on by default on these models — depth is set with `output_config.effort`;
* `stop_reason` is checked before the content is trusted (refusal / max_tokens);
* on Claude Opus 5.5 a server-side refusal fallback is enabled by default
  (`fallbacks: "default"` on the beta endpoint); CRAWLER_REFUSAL_FALLBACK=0 turns it off;
* errors are caught most-specific first (BadRequest → RateLimit → APIStatus → APIConnection).

The client object is injected, so tests use a fake with the same `.messages.create`
shape and never touch the network. ANTHROPIC_API_KEY is read by the SDK from the
environment; this module never sees it.
"""

from __future__ import annotations

import base64
import json
import logging
import threading
from dataclasses import asdict, dataclass, field
from typing import Any

from .documents import ExtractedText
from .schema import coerce_extraction, coerce_triage, extraction_schema, triage_schema

try:  # the SDK is a runtime dependency; tests inject a fake client and may run without it
    import anthropic
except ImportError:  # pragma: no cover
    anthropic = None  # type: ignore[assignment]

log = logging.getLogger("auditioner.crawler.llm")

FALLBACK_BETA = "server-side-fallback-2026-07-01"

# Price snapshot from the claude-api skill (2026-10), USD per million tokens. Used only
# to log an estimate per list; the Anthropic console is the source of truth for bills.
PRICES_PER_MTOK: dict[str, dict[str, float]] = {
    "claude-opus-5-5": {"input": 4.00, "output": 20.00, "cache_read": 0.20, "cache_write": 5.00},
    "claude-haiku-5-5": {"input": 0.10, "output": 0.50, "cache_read": 0.01, "cache_write": 0.125},
}

EXTRACTION_SYSTEM = """You read orchestra audition announcements and repertoire lists for Auditioner, an app that helps musicians prepare for orchestra auditions. Your output is reviewed by a professional cellist before anything is shown to users, and every fact you report is checked by a program against the lines you cite. Your job is transcription into a fixed structure, not interpretation.

You receive one source: the numbered text lines of a web page or document (each line starts with an id such as L0012), and when the source is a PDF, the PDF itself so you can see the layout (tables, columns, boxed rehearsal letters). Use the PDF to understand which text belongs together; always report the facts from the numbered lines and cite the line ids.

Rules — follow them exactly:
1. Report only what the source prints. Never add, complete or infer bar numbers, rehearsal marks, movements, catalogue numbers, dates, instruments or works. If the source gives a work without bars, leave startBar and endBar at 0 and set the location type accordingly ("whole" only when the source says so; otherwise "unknown"). If the source gives a rehearsal-mark range ("4 before C to D"), type is "rehearsal_mark" and the bar fields stay 0.
2. Every item and every date must cite sourceLineIds: the ids of the lines the fact was read from. Copy the text of those lines into rawText verbatim. An item whose composer or work does not appear in its cited lines will be rejected.
3. Keep the source's wording. "Dvořák" stays "Dvořák"; "R. Strauss" stays "R. Strauss"; "Sym. No. 5" stays as printed in rawText, while composer/work fields hold just the composer and the work title as printed. Do not translate titles.
4. One source may describe several vacancies (for example "Section Cello" and "Assistant Principal Cello" with different lists). Make one vacancy per position, each with its own items. A single list shared by several positions becomes one vacancy per position with the same items.
5. instrument is the catalogue id the vacancy is for (cello, double-bass, horn, bass-trombone, english-horn, e-flat-clarinet, keyboard ...). Use "other" when the instrument is not in the list. Do not guess from the orchestra name.
6. listCompleteness: "full" when the source prints a complete excerpt list with locations; "partial_public" when it says more excerpts will be sent later or only part is public; "works_only" when works are named without excerpt locations; "revealed_on_invitation" when the list goes to invited candidates only; "unknown" otherwise.
7. category: "solo" for concertos and solo pieces, "excerpt" for orchestral excerpts, "sight_reading" when sight reading is announced, "chamber" for chamber works, "other" for anything else (scales, mock rehearsal).
8. round: copy the round label the source attaches to the item ("Preliminary round", "Final"), or "" when the source does not organise items by round.
9. Dates: applicationDeadline and auditionDates take ISO dates (YYYY-MM-DD) only when the source prints the complete date; cite the lines. If a date is incomplete or ambiguous, leave value "" and mention it in sourceNotes.
10. Ignore everything that is not about an orchestra audition or vacancy: concerts, education programmes, staff jobs, cookie notices, navigation. If the source announces no audition, set isAuditionNotice false and return no vacancies.
11. Never copy personal names, email addresses or phone numbers of staff into any field. The orchestra name and the position are enough.
12. Do not describe your reasoning in the output. Fill the schema; put reviewer-relevant remarks in sourceNotes in one or two plain sentences.

When the source is a scanned PDF with no text lines, you may still read the vacancy details from the image, but items cannot cite lines: leave sourceLineIds empty and explain in sourceNotes that the PDF is a scan. Those items go straight to human review."""

TRIAGE_SYSTEM = """You classify web pages for Auditioner's audition crawler. You receive the readable text of one page from an orchestra's own website and a list of links found on it (address and link text). Decide, from the text alone:

- hasAuditionContent: the page is about orchestra auditions, musician vacancies, Probespiele, audizioni, concours de recrutement or repertoire/excerpt lists for such auditions. Concerts, education programmes, administrative jobs and news are not audition content.
- pageHasRepertoireList: the page text itself lists works or excerpts to prepare (composer and work names in a list), as opposed to merely linking to a PDF.
- instruments: the catalogue instrument ids (cello, violin, viola, double-bass, harp, flute, piccolo, oboe, english-horn, clarinet, e-flat-clarinet, bass-clarinet, bassoon, contrabassoon, horn, trumpet, trombone, bass-trombone, tuba, timpani, percussion, keyboard, other) with an open vacancy on this page. Only what the page says.
- documentsToExtract: the addresses, copied exactly from the link list, of documents that are repertoire lists, excerpt lists or audition announcements worth reading in full. Leave out brochures, season programmes, annual reports and forms.
- notes: one short line for the log.

Do not invent anything; when unsure, leave fields empty or false."""


class LLMFatal(Exception):
    """Something no retry will fix this run (bad key, unknown model, no permission)."""


@dataclass
class Usage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_input_tokens: int = 0
    cache_creation_input_tokens: int = 0

    def add(self, other: Usage) -> None:
        self.input_tokens += other.input_tokens
        self.output_tokens += other.output_tokens
        self.cache_read_input_tokens += other.cache_read_input_tokens
        self.cache_creation_input_tokens += other.cache_creation_input_tokens

    def to_dict(self) -> dict[str, int]:
        return asdict(self)


@dataclass
class LLMResult:
    ok: bool
    model: str
    data: dict[str, Any] | None = None
    stop_reason: str | None = None
    error: str | None = None
    refusal: dict[str, Any] | None = None
    usage: Usage = field(default_factory=Usage)
    request_id: str | None = None
    estimated_cost_usd: float = 0.0


def estimate_cost_usd(model: str, usage: Usage) -> float:
    prices = PRICES_PER_MTOK.get(model)
    if prices is None:
        return 0.0
    return (
        usage.input_tokens * prices["input"]
        + usage.output_tokens * prices["output"]
        + usage.cache_read_input_tokens * prices["cache_read"]
        + usage.cache_creation_input_tokens * prices["cache_write"]
    ) / 1_000_000


def _usage_of(response: Any) -> Usage:
    usage = getattr(response, "usage", None)
    if usage is None:
        return Usage()

    def get(name: str) -> int:
        value = getattr(usage, name, None)
        if value is None and isinstance(usage, dict):
            value = usage.get(name)
        return int(value or 0)

    return Usage(
        input_tokens=get("input_tokens"),
        output_tokens=get("output_tokens"),
        cache_read_input_tokens=get("cache_read_input_tokens"),
        cache_creation_input_tokens=get("cache_creation_input_tokens"),
    )


def _first_text(response: Any) -> str | None:
    for block in getattr(response, "content", None) or []:
        kind = getattr(block, "type", None) or (block.get("type") if isinstance(block, dict) else None)
        if kind == "text":
            return getattr(block, "text", None) if not isinstance(block, dict) else block.get("text")
    return None


def _stop_details(response: Any) -> dict[str, Any] | None:
    details = getattr(response, "stop_details", None)
    if details is None:
        return None
    return {
        "type": getattr(details, "type", None),
        "category": getattr(details, "category", None),
        "explanation": getattr(details, "explanation", None),
    }


def make_client() -> Any:
    """A real Anthropic client (credentials from the environment)."""
    if anthropic is None:  # pragma: no cover
        raise LLMFatal("the anthropic package is not installed")
    return anthropic.Anthropic()


class ExtractionClient:
    def __init__(
        self,
        client: Any,
        *,
        extraction_model: str = "claude-opus-5-5",
        triage_model: str = "claude-haiku-5-5",
        extraction_effort: str = "high",
        extraction_max_tokens: int = 20000,
        triage_max_tokens: int = 2048,
        refusal_fallback: bool = True,
        pdf_block_max_bytes: int = 10 * 1024 * 1024,
        pdf_block_max_pages: int = 100,
        max_source_lines: int = 4000,
    ) -> None:
        self.client = client
        self.extraction_model = extraction_model
        self.triage_model = triage_model
        self.extraction_effort = extraction_effort
        self.extraction_max_tokens = extraction_max_tokens
        self.triage_max_tokens = triage_max_tokens
        self.refusal_fallback = refusal_fallback
        self.pdf_block_max_bytes = pdf_block_max_bytes
        self.pdf_block_max_pages = pdf_block_max_pages
        self.max_source_lines = max_source_lines
        self.total_usage: dict[str, Usage] = {}
        self.calls = 0
        self._lock = threading.Lock()  # the pipeline may call from several threads

    # ------------------------------------------------------------- request shapes

    @staticmethod
    def _system(text: str) -> list[dict[str, Any]]:
        return [{"type": "text", "text": text, "cache_control": {"type": "ephemeral"}}]

    def build_triage_params(self, *, orchestra_name: str, page_url: str, page_text: str,
                            links: list[tuple[str, str]], max_chars: int = 12000) -> dict[str, Any]:
        text = page_text if len(page_text) <= max_chars else page_text[:max_chars] + "\n[... page text cut here]"
        link_lines = "\n".join(f"- {url}  ({label[:120]})" if label else f"- {url}" for url, label in links[:60]) or "- (none)"
        user = (
            f"Orchestra (from our registry): {orchestra_name}\n"
            f"Page address: {page_url}\n\n"
            f"Page text:\n{text}\n\n"
            f"Links found on the page:\n{link_lines}"
        )
        return {
            "model": self.triage_model,
            "max_tokens": self.triage_max_tokens,
            "system": self._system(TRIAGE_SYSTEM),
            "messages": [{"role": "user", "content": [{"type": "text", "text": user}]}],
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": triage_schema()}},
        }

    def build_extraction_params(
        self,
        *,
        orchestra_name: str,
        orchestra_country: str,
        source_url: str,
        source: ExtractedText,
        pdf_bytes: bytes | None = None,
        hints: list[str] | None = None,
    ) -> dict[str, Any]:
        content: list[dict[str, Any]] = []
        pdf_attached = False
        if (
            pdf_bytes
            and source.kind == "pdf"
            and len(pdf_bytes) <= self.pdf_block_max_bytes
            and (source.pages or 0) <= self.pdf_block_max_pages
        ):
            content.append(
                {
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": base64.standard_b64encode(pdf_bytes).decode("ascii"),
                    },
                    "title": source_url.rsplit("/", 1)[-1][:120] or "repertoire list",
                }
            )
            pdf_attached = True
        numbered = source.numbered(self.max_source_lines) if source.lines else "(no text lines — see sourceNotes rule for scans)"
        hint_text = ""
        if hints:
            hint_text = "\nContext from our registry (not a source of facts; do not cite it):\n" + "\n".join(f"- {h}" for h in hints) + "\n"
        description = f"{source.kind} document" + (f", {source.pages} pages" if source.pages else "")
        if pdf_attached:
            description += " (the PDF is attached above)"
        user = (
            f"Orchestra (from our registry): {orchestra_name}, {orchestra_country}\n"
            f"Source address: {source_url}\n"
            f"Source type: {description}\n"
            f"{hint_text}\n"
            f"Numbered source lines:\n{numbered}"
        )
        content.append({"type": "text", "text": user})
        return {
            "model": self.extraction_model,
            "max_tokens": self.extraction_max_tokens,
            "system": self._system(EXTRACTION_SYSTEM),
            "messages": [{"role": "user", "content": content}],
            "output_config": {
                "effort": self.extraction_effort,
                "format": {"type": "json_schema", "schema": extraction_schema()},
            },
        }

    # ------------------------------------------------------------- calls

    def _create(self, params: dict[str, Any], *, allow_fallback: bool) -> Any:
        if allow_fallback and self.refusal_fallback:
            return self.client.beta.messages.create(betas=[FALLBACK_BETA], fallbacks="default", **params)
        return self.client.messages.create(**params)

    def _call(self, params: dict[str, Any], *, allow_fallback: bool, coerce: Any) -> LLMResult:
        model = params["model"]
        with self._lock:
            self.calls += 1
        try:
            response = self._create(params, allow_fallback=allow_fallback)
        except Exception as exc:  # classified below, most specific first
            return self._error_result(model, exc)
        return self._parse(response, model, coerce)

    def _error_result(self, model: str, exc: Exception) -> LLMResult:
        if anthropic is not None:
            if isinstance(exc, (anthropic.AuthenticationError, anthropic.PermissionDeniedError)):
                raise LLMFatal(f"Anthropic rejected the credentials ({exc.__class__.__name__})") from exc
            if isinstance(exc, anthropic.NotFoundError):
                raise LLMFatal(f"model '{model}' not found or not available to this account") from exc
            if isinstance(exc, anthropic.BadRequestError):
                return LLMResult(ok=False, model=model, error=f"bad request: {getattr(exc, 'message', exc)}"[:500])
            if isinstance(exc, anthropic.RateLimitError):
                return LLMResult(ok=False, model=model, error="rate limited by the Anthropic API after retries")
            if isinstance(exc, anthropic.APIStatusError):
                return LLMResult(ok=False, model=model, error=f"API error {exc.status_code} ({getattr(exc, 'type', '')})")
            if isinstance(exc, anthropic.APIConnectionError):
                return LLMResult(ok=False, model=model, error="could not reach the Anthropic API")
        log.exception("unexpected error calling %s", model)
        return LLMResult(ok=False, model=model, error=f"unexpected error: {exc.__class__.__name__}")

    def _parse(self, response: Any, model: str, coerce: Any) -> LLMResult:
        usage = _usage_of(response)
        with self._lock:
            self.total_usage.setdefault(model, Usage()).add(usage)
        served_model = getattr(response, "model", None) or model
        cost = estimate_cost_usd(served_model if served_model in PRICES_PER_MTOK else model, usage)
        result = LLMResult(
            ok=False,
            model=served_model,
            stop_reason=getattr(response, "stop_reason", None),
            usage=usage,
            request_id=getattr(response, "_request_id", None),
            estimated_cost_usd=cost,
        )
        if result.stop_reason == "refusal":
            result.refusal = _stop_details(response)
            result.error = "the model declined this request (refusal)"
            return result
        if result.stop_reason == "max_tokens":
            result.error = "output was cut off (max_tokens) — the list may be too long for one call"
            return result
        text = _first_text(response)
        if not text:
            result.error = "no text in the response"
            return result
        try:
            raw = json.loads(text)
        except ValueError:
            result.error = "response was not valid JSON"
            return result
        result.data = coerce(raw)
        result.ok = True
        return result

    def triage(self, **kwargs: Any) -> LLMResult:
        params = self.build_triage_params(**kwargs)
        result = self._call(params, allow_fallback=False, coerce=coerce_triage)
        log.info("triage %s: %s (%s)", kwargs.get("page_url"), "ok" if result.ok else result.error,
                 f"~${result.estimated_cost_usd:.4f}")
        return result

    def extract(self, **kwargs: Any) -> LLMResult:
        params = self.build_extraction_params(**kwargs)
        result = self._call(params, allow_fallback=True, coerce=coerce_extraction)
        log.info("extract %s: %s (in %d, out %d, cache read %d, ~$%.3f)", kwargs.get("source_url"),
                 "ok" if result.ok else result.error, result.usage.input_tokens, result.usage.output_tokens,
                 result.usage.cache_read_input_tokens, result.estimated_cost_usd)
        return result

    # ------------------------------------------------------------- Batch API

    def submit_extraction_batch(self, jobs: list[tuple[str, dict[str, Any]]]) -> str:
        """Submit many extraction requests at 50% price. `jobs` are (custom_id, params)
        built with build_extraction_params. Results come back later via collect_batch.
        The refusal-fallback parameter is not accepted on Batches, so it is not sent."""
        requests = [{"custom_id": custom_id, "params": params} for custom_id, params in jobs]
        batch = self.client.messages.batches.create(requests=requests)
        return batch.id

    def collect_batch(self, batch_id: str) -> dict[str, LLMResult] | None:
        """None while the batch is still processing; otherwise results keyed by custom_id."""
        batch = self.client.messages.batches.retrieve(batch_id)
        if getattr(batch, "processing_status", None) != "ended":
            return None
        results: dict[str, LLMResult] = {}
        for entry in self.client.messages.batches.results(batch_id):
            outcome = entry.result
            if outcome.type == "succeeded":
                results[entry.custom_id] = self._parse(outcome.message, self.extraction_model, coerce_extraction)
            else:
                detail = getattr(getattr(outcome, "error", None), "type", None) or outcome.type
                results[entry.custom_id] = LLMResult(ok=False, model=self.extraction_model, error=f"batch item {outcome.type}: {detail}")
        return results

    def total_cost_usd(self) -> float:
        return sum(estimate_cost_usd(model, usage) for model, usage in self.total_usage.items())
