"""POST /v1/feedback and the Supabase store, with an httpx MockTransport (no network)."""

from __future__ import annotations

import hashlib
import json
import logging
from typing import Any, Callable

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.feedback import FALLBACK_SALT_PREFIX, FeedbackStore, FeedbackStoreError, device_hash, hash_salt
from app.main import MSG_FEEDBACK_OFF, create_app
from conftest import DEVICE

SUPABASE_URL = "https://abcdefgh.supabase.co"
SERVICE_KEY = "service-role-key-for-tests"
SALT = "pepper"
SECRET_PHRASE = "QUOKKA-7731 the bar numbers in the pitfalls note are wrong"


class Recorder:
    """MockTransport handler that records every request and answers with `status`."""

    def __init__(self, status: int = 201, body: bytes = b"", raise_error: Exception | None = None) -> None:
        self.status = status
        self.body = body
        self.raise_error = raise_error
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.raise_error is not None:
            raise self.raise_error
        return httpx.Response(self.status, content=self.body, request=request)

    def rows(self) -> list[dict[str, Any]]:
        return [json.loads(r.content) for r in self.requests]


def feedback_app(settings_factory: Callable[..., Settings], handler: Recorder, **overrides: Any):
    values: dict[str, Any] = {
        "supabase_url": SUPABASE_URL,
        "supabase_service_role_key": SERVICE_KEY,
        "feedback_hash_salt": SALT,
    }
    values.update(overrides)
    settings = settings_factory(**values)
    app = create_app(settings)
    app.state.feedback = FeedbackStore(
        settings.supabase_url,
        settings.supabase_service_role_key,
        settings.feedback_hash_salt,
        transport=httpx.MockTransport(handler),
    )
    return app


def payload(**changes: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "context": "excerpt-note:pitfalls",
        "excerptId": "cello-strauss-don-juan-opening",
        "message": SECRET_PHRASE,
        "appVersion": "0.1",
    }
    body.update(changes)
    return {k: v for k, v in body.items() if v is not ...}


# ------------------------------------------------------------------ happy path


def test_stores_row_with_hashed_device_id(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))

    response = client.post("/v1/feedback", json=payload(), headers=DEVICE)

    assert response.status_code == 201
    assert response.json() == {"status": "received"}
    assert len(recorder.requests) == 1
    request = recorder.requests[0]
    assert request.method == "POST"
    assert str(request.url) == f"{SUPABASE_URL}/rest/v1/feedback"
    assert request.headers["apikey"] == SERVICE_KEY
    assert request.headers["authorization"] == f"Bearer {SERVICE_KEY}"
    assert request.headers["prefer"] == "return=minimal"

    row = recorder.rows()[0]
    expected_hash = hashlib.sha256((SALT + DEVICE["X-Device-Id"]).encode()).hexdigest()
    assert row == {
        "context": "excerpt-note:pitfalls",
        "excerpt_id": "cello-strauss-don-juan-opening",
        "message": SECRET_PHRASE,
        "app_version": "0.1",
        "device_hash": expected_hash,
    }
    assert DEVICE["X-Device-Id"] not in request.content.decode()


def test_message_is_trimmed_and_optional_fields_default_to_null(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))

    body = {"context": "settings", "message": "  \n  Love the loop tool.  \n"}
    response = client.post("/v1/feedback", json=body, headers=DEVICE)

    assert response.status_code == 201
    row = recorder.rows()[0]
    assert row["message"] == "Love the loop tool."
    assert row["excerpt_id"] is None
    assert row["app_version"] is None


def test_message_at_the_limit_is_accepted(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post("/v1/feedback", json=payload(message="x" * 2000 + "\n\n"), headers=DEVICE)
    assert response.status_code == 201
    assert len(recorder.rows()[0]["message"]) == 2000


# ------------------------------------------------------------------ not configured


def test_503_when_supabase_is_not_configured(client, app):
    response = client.post("/v1/feedback", json=payload(), headers=DEVICE)
    assert response.status_code == 503
    assert response.json() == {"detail": MSG_FEEDBACK_OFF}
    assert not app.state.feedback.configured


def test_503_when_only_one_value_is_set(settings_factory):
    recorder = Recorder()
    app = feedback_app(settings_factory, recorder, supabase_service_role_key="")
    response = TestClient(app).post("/v1/feedback", json=payload(), headers=DEVICE)
    assert response.status_code == 503
    assert recorder.requests == []


def test_unconfigured_does_not_charge_the_limit(settings_factory):
    recorder = Recorder()
    app = feedback_app(settings_factory, recorder, supabase_url="", daily_feedback_limit=2)
    client = TestClient(app)
    for _ in range(5):
        assert client.post("/v1/feedback", json=payload(), headers=DEVICE).status_code == 503
    assert app.state.feedback_limiter.remaining(DEVICE["X-Device-Id"]) == 2


# ------------------------------------------------------------------ validation


def test_missing_device_header_is_400(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post("/v1/feedback", json=payload())
    assert response.status_code == 400
    assert "X-Device-Id" in response.json()["detail"]
    assert recorder.requests == []


def test_blank_message_is_400(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post("/v1/feedback", json=payload(message="   \n\t "), headers=DEVICE)
    assert response.status_code == 400
    assert response.json()["detail"] == "Write a few words first."
    assert recorder.requests == []


def test_too_long_after_trimming_is_400(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post("/v1/feedback", json=payload(message="y" * 2001), headers=DEVICE)
    assert response.status_code == 400
    assert "too long" in response.json()["detail"]
    assert recorder.requests == []


@pytest.mark.parametrize(
    "changes, field",
    [
        ({"context": "Excerpt-Note"}, "context"),  # uppercase
        ({"context": "has space"}, "context"),
        ({"context": "x" * 65}, "context"),
        ({"context": ""}, "context"),
        ({"context": ...}, "context"),  # missing
        ({"message": ...}, "message"),  # missing
        ({"message": ""}, "message"),
        ({"message": "z" * 4001}, "message"),  # over the raw cap
        ({"excerptId": "e" * 129}, "excerptId"),
        ({"appVersion": "v" * 33}, "appVersion"),
        ({"message": 12}, "message"),  # wrong type
    ],
)
def test_schema_violations_are_422(settings_factory, changes, field):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post("/v1/feedback", json=payload(**changes), headers=DEVICE)
    assert response.status_code == 422
    body = response.json()
    assert list(body) == ["detail"]
    assert field in body["detail"]
    assert recorder.requests == []


def test_not_json_is_422(settings_factory):
    recorder = Recorder()
    client = TestClient(feedback_app(settings_factory, recorder))
    response = client.post(
        "/v1/feedback", content=b"context=settings", headers={**DEVICE, "Content-Type": "text/plain"}
    )
    assert response.status_code == 422
    assert recorder.requests == []


# ------------------------------------------------------------------ limits


def test_daily_limit_20_then_429(settings_factory):
    recorder = Recorder()
    app = feedback_app(settings_factory, recorder)
    client = TestClient(app)
    for _ in range(20):
        assert client.post("/v1/feedback", json=payload(), headers=DEVICE).status_code == 201
    blocked = client.post("/v1/feedback", json=payload(), headers=DEVICE)
    assert blocked.status_code == 429
    assert blocked.json()["detail"] == "You've sent a lot of feedback today. Try again tomorrow."
    assert len(recorder.requests) == 20
    # another device is independent
    other = {"X-Device-Id": "another-device"}
    assert client.post("/v1/feedback", json=payload(), headers=other).status_code == 201


def test_feedback_limit_is_separate_from_scan_limit(settings_factory):
    recorder = Recorder()
    app = feedback_app(settings_factory, recorder, daily_scan_limit=1, daily_feedback_limit=3)
    client = TestClient(app)
    for _ in range(3):
        assert client.post("/v1/feedback", json=payload(), headers=DEVICE).status_code == 201
    assert client.post("/v1/feedback", json=payload(), headers=DEVICE).status_code == 429
    assert app.state.limiter.remaining(DEVICE["X-Device-Id"]) == 1


# ------------------------------------------------------------------ Supabase failures


@pytest.mark.parametrize("status", [401, 404, 409, 500, 503])
def test_supabase_error_status_is_502_and_not_charged(settings_factory, status):
    recorder = Recorder(status=status, body=b'{"message":"details that must not leak"}')
    app = feedback_app(settings_factory, recorder, daily_feedback_limit=5)
    response = TestClient(app).post("/v1/feedback", json=payload(), headers=DEVICE)
    assert response.status_code == 502
    assert response.json() == {"detail": "Our feedback store didn't answer. Try again later."}
    assert app.state.feedback_limiter.remaining(DEVICE["X-Device-Id"]) == 5


def test_supabase_unreachable_is_502(settings_factory):
    recorder = Recorder(raise_error=httpx.ConnectError("boom"))
    app = feedback_app(settings_factory, recorder)
    response = TestClient(app).post("/v1/feedback", json=payload(), headers=DEVICE)
    assert response.status_code == 502


def test_supabase_timeout_is_502(settings_factory):
    recorder = Recorder(raise_error=httpx.ReadTimeout("slow"))
    app = feedback_app(settings_factory, recorder)
    response = TestClient(app).post("/v1/feedback", json=payload(), headers=DEVICE)
    assert response.status_code == 502


# ------------------------------------------------------------------ logging


def test_message_and_device_id_are_never_logged(settings_factory, caplog):
    caplog.set_level(logging.DEBUG)
    ok = Recorder()
    failing = Recorder(status=500, body=SECRET_PHRASE.encode())
    for recorder in (ok, failing):
        client = TestClient(feedback_app(settings_factory, recorder))
        client.post("/v1/feedback", json=payload(), headers=DEVICE)
        client.post("/v1/feedback", json=payload(message="   "), headers=DEVICE)

    assert any("feedback stored" in r.getMessage() for r in caplog.records)
    assert any("feedback store answered 500" in r.getMessage() for r in caplog.records)
    for record in caplog.records:
        text = record.getMessage()
        assert SECRET_PHRASE not in text
        assert "QUOKKA" not in text
        assert DEVICE["X-Device-Id"] not in text
        assert SERVICE_KEY not in text


def test_fallback_salt_warning_once_at_startup(settings_factory, caplog):
    caplog.set_level(logging.WARNING)
    create_app(settings_factory(supabase_url=SUPABASE_URL, supabase_service_role_key=SERVICE_KEY))
    assert any("FEEDBACK_HASH_SALT" in r.getMessage() for r in caplog.records)
    caplog.clear()
    create_app(settings_factory(supabase_url=SUPABASE_URL, supabase_service_role_key=SERVICE_KEY, feedback_hash_salt="s"))
    create_app(settings_factory())  # off → no warning either
    assert not any("FEEDBACK_HASH_SALT" in r.getMessage() for r in caplog.records)


# ------------------------------------------------------------------ store unit tests


def test_hash_salt_fallback_derived_from_url():
    assert hash_salt("pepper", SUPABASE_URL) == "pepper"
    assert hash_salt("  pepper ", SUPABASE_URL) == "pepper"
    assert hash_salt("", "https://x.supabase.co/") == FALLBACK_SALT_PREFIX + "https://x.supabase.co"
    assert hash_salt(None, None) == FALLBACK_SALT_PREFIX
    assert device_hash("s", "d") == hashlib.sha256(b"sd").hexdigest()


def test_store_flags_and_repr_hide_the_key():
    store = FeedbackStore(SUPABASE_URL + "/", SERVICE_KEY, "")
    assert store.configured
    assert store.salt_is_fallback
    assert store.url == SUPABASE_URL
    assert store.endpoint == f"{SUPABASE_URL}/rest/v1/feedback"
    assert SERVICE_KEY not in repr(store)
    assert store.device_hash("abc") == device_hash(FALLBACK_SALT_PREFIX + SUPABASE_URL, "abc")

    off = FeedbackStore("", "", "")
    assert not off.configured


@pytest.mark.anyio
async def test_store_raises_when_not_configured():
    store = FeedbackStore("", "", "")
    with pytest.raises(FeedbackStoreError):
        await store.store(context="settings", excerpt_id=None, message="m", app_version=None, device_id="d")


def test_settings_from_env_reads_feedback_values():
    settings = Settings.from_env(
        {
            "SUPABASE_URL": " https://abcdefgh.supabase.co/ ",
            "SUPABASE_SERVICE_ROLE_KEY": " key ",
            "FEEDBACK_HASH_SALT": "salt",
            "DAILY_FEEDBACK_LIMIT": "7",
        }
    )
    assert settings.supabase_url == SUPABASE_URL
    assert settings.supabase_service_role_key == "key"
    assert settings.feedback_hash_salt == "salt"
    assert settings.daily_feedback_limit == 7

    defaults = Settings.from_env({})
    assert defaults.supabase_url == ""
    assert defaults.supabase_service_role_key == ""
    assert defaults.feedback_hash_salt == ""
    assert defaults.daily_feedback_limit == 20
