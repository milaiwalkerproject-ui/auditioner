from __future__ import annotations

import base64
import json

import pytest

from crawler.documents import pdf_text, text_document
from crawler.llm import (
    FALLBACK_BETA,
    ExtractionClient,
    LLMFatal,
    Usage,
    estimate_cost_usd,
)

from .conftest import FakeAnthropic, FakeResponse, make_pdf, user_text

LINES = ["Section Cello", "Beethoven: Symphony No. 5, II, mm. 1-106"]


def extraction_json(**overrides):
    data = {
        "isAuditionNotice": True,
        "language": "en",
        "vacancies": [
            {
                "orchestra": "Example", "position": "Section Cello", "instrument": "cello", "chair": "",
                "applicationDeadline": {"value": "", "sourceLineIds": []}, "auditionDates": [], "listCompleteness": "full",
                "items": [
                    {"sourceLineIds": ["L0002"], "rawText": LINES[1], "round": "", "category": "excerpt", "composer": "Beethoven",
                     "work": "Symphony No. 5", "catalogueNumber": "", "movement": "II", "part": "",
                     "location": {"type": "measures", "startText": "mm. 1", "endText": "106", "startBar": 1, "endBar": 106}, "notes": ""}
                ],
            }
        ],
        "sourceNotes": "",
    }
    data.update(overrides)
    return data


def test_extraction_request_shape_follows_the_sdk_rules():
    fake = FakeAnthropic(lambda kwargs: extraction_json())
    client = ExtractionClient(fake, extraction_model="claude-opus-5-5", triage_model="claude-haiku-5-5")
    pdf = make_pdf(LINES)
    result = client.extract(orchestra_name="Example Phil", orchestra_country="US", source_url="https://x.example/list.pdf",
                            source=pdf_text(pdf), pdf_bytes=pdf, hints=["registry notes: fixture"])
    assert result.ok and result.data["vacancies"][0]["items"][0]["composer"] == "Beethoven"
    path, kwargs = fake.calls[0]
    assert path == "beta.messages"  # refusal fallback on by default for the Opus call
    assert kwargs["betas"] == [FALLBACK_BETA] and kwargs["fallbacks"] == "default"
    assert kwargs["model"] == "claude-opus-5-5"
    assert kwargs["max_tokens"] >= 16000
    assert kwargs["output_config"]["effort"] == "high"
    assert kwargs["output_config"]["format"]["type"] == "json_schema"
    assert kwargs["output_config"]["format"]["schema"]["properties"]["vacancies"]
    assert "thinking" not in kwargs  # on by default on Claude Opus 5.5; never budget_tokens
    assert "tool_choice" not in kwargs
    system = kwargs["system"]
    assert system[0]["cache_control"] == {"type": "ephemeral"} and "Never add" in system[0]["text"]
    content = kwargs["messages"][0]["content"]
    assert content[0]["type"] == "document" and content[0]["source"]["media_type"] == "application/pdf"
    assert base64.standard_b64decode(content[0]["source"]["data"]) == pdf
    assert "\n" not in content[0]["source"]["data"]
    text = user_text(kwargs)
    assert "L0002: " + LINES[1] in text
    assert "registry notes: fixture" in text and "the PDF is attached" in text
    assert result.estimated_cost_usd > 0
    assert client.total_cost_usd() == pytest.approx(result.estimated_cost_usd)


def test_fallback_can_be_switched_off_and_pdf_block_respects_limits():
    fake = FakeAnthropic(lambda kwargs: extraction_json())
    client = ExtractionClient(fake, refusal_fallback=False, pdf_block_max_bytes=10)
    pdf = make_pdf(LINES)
    client.extract(orchestra_name="x", orchestra_country="", source_url="https://x/list.pdf", source=pdf_text(pdf), pdf_bytes=pdf)
    path, kwargs = fake.calls[0]
    assert path == "messages" and "betas" not in kwargs and "fallbacks" not in kwargs
    assert all(block["type"] == "text" for block in kwargs["messages"][0]["content"])


def test_triage_uses_haiku_at_low_effort_without_fallback():
    fake = FakeAnthropic(lambda kwargs: {"hasAuditionContent": True, "pageHasRepertoireList": False, "instruments": ["cello"],
                                         "documentsToExtract": ["https://x/list.pdf"], "notes": "ok"})
    client = ExtractionClient(fake)
    result = client.triage(orchestra_name="x", page_url="https://x/auditions", page_text="Section Cello audition",
                           links=[("https://x/list.pdf", "Repertoire")])
    assert result.ok and result.data["documentsToExtract"] == ["https://x/list.pdf"]
    path, kwargs = fake.calls[0]
    assert path == "messages" and kwargs["model"] == "claude-haiku-5-5"
    assert kwargs["output_config"]["effort"] == "low"
    assert kwargs["system"][0]["cache_control"] == {"type": "ephemeral"}
    assert "https://x/list.pdf  (Repertoire)" in user_text(kwargs)


def test_refusal_and_max_tokens_are_reported_not_trusted():
    fake = FakeAnthropic(lambda kwargs: FakeResponse(stop_reason="refusal", stop_details=type("D", (), {"type": "refusal", "category": "other", "explanation": "x"})()))
    client = ExtractionClient(fake)
    source = text_document("\n".join(LINES))
    refused = client.extract(orchestra_name="x", orchestra_country="", source_url="u", source=source)
    assert not refused.ok and "refusal" in refused.error and refused.refusal["category"] == "other"

    fake = FakeAnthropic(lambda kwargs: FakeResponse(data=extraction_json(), stop_reason="max_tokens"))
    cut = ExtractionClient(fake).extract(orchestra_name="x", orchestra_country="", source_url="u", source=source)
    assert not cut.ok and "max_tokens" in cut.error

    fake = FakeAnthropic(lambda kwargs: FakeResponse(text="{not json"))
    bad = ExtractionClient(fake).extract(orchestra_name="x", orchestra_country="", source_url="u", source=source)
    assert not bad.ok and "JSON" in bad.error


def test_sdk_errors_are_classified_most_specific_first():
    anthropic = pytest.importorskip("anthropic")
    import httpx2

    def status_error(cls, status):
        response = httpx2.Response(status, request=httpx2.Request("POST", "https://api.anthropic.com/v1/messages"))
        return cls("boom", response=response, body={"error": {"type": "x", "message": "boom"}})

    source = text_document("x")
    client = ExtractionClient(FakeAnthropic(lambda kwargs: status_error(anthropic.RateLimitError, 429)))
    assert "rate limited" in client.extract(orchestra_name="x", orchestra_country="", source_url="u", source=source).error
    client = ExtractionClient(FakeAnthropic(lambda kwargs: status_error(anthropic.BadRequestError, 400)))
    assert "bad request" in client.extract(orchestra_name="x", orchestra_country="", source_url="u", source=source).error
    client = ExtractionClient(FakeAnthropic(lambda kwargs: status_error(anthropic.InternalServerError, 500)))
    assert "API error 500" in client.extract(orchestra_name="x", orchestra_country="", source_url="u", source=source).error
    client = ExtractionClient(FakeAnthropic(lambda kwargs: anthropic.APIConnectionError(request=httpx2.Request("POST", "https://api.anthropic.com"))))
    assert "could not reach" in client.extract(orchestra_name="x", orchestra_country="", source_url="u", source=source).error
    with pytest.raises(LLMFatal):
        ExtractionClient(FakeAnthropic(lambda kwargs: status_error(anthropic.AuthenticationError, 401))).extract(
            orchestra_name="x", orchestra_country="", source_url="u", source=source)
    with pytest.raises(LLMFatal):
        ExtractionClient(FakeAnthropic(lambda kwargs: status_error(anthropic.NotFoundError, 404))).extract(
            orchestra_name="x", orchestra_country="", source_url="u", source=source)


def test_batch_submission_and_collection_use_the_same_request_shape():
    fake = FakeAnthropic(lambda kwargs: extraction_json())
    client = ExtractionClient(fake)
    source = text_document("\n".join(LINES))
    params = client.build_extraction_params(orchestra_name="x", orchestra_country="US", source_url="https://x/a.pdf", source=source)
    batch_id = client.submit_extraction_batch([("job-1", params)])
    assert batch_id == "msgbatch_1"
    submitted = fake.messages.batches.created[0][0]
    assert submitted["custom_id"] == "job-1" and submitted["params"]["model"] == "claude-opus-5-5"
    assert "fallbacks" not in submitted["params"]
    fake.messages.batches.status = "in_progress"
    assert client.collect_batch(batch_id) is None
    fake.messages.batches.status = "ended"
    results = client.collect_batch(batch_id)
    assert results["job-1"].ok and results["job-1"].data["vacancies"][0]["position"] == "Section Cello"


def test_cost_estimate_uses_the_price_table():
    usage = Usage(input_tokens=1_000_000, output_tokens=0)
    assert estimate_cost_usd("claude-opus-5-5", usage) == pytest.approx(4.0)
    assert estimate_cost_usd("claude-haiku-5-5", usage) == pytest.approx(0.10)
    assert estimate_cost_usd("unknown-model", usage) == 0.0
    assert json.dumps(usage.to_dict())
