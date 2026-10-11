"""Storing "Report an error" / "Send feedback" messages (POST /v1/feedback) in Supabase.

One PostgREST insert into the ``feedback`` table (supabase/migrations/…_feedback.sql),
authenticated with the service-role key, which bypasses row level security — the table
has no policies, so nothing else can read it. Rules that matter for privacy:

- the message body is never logged, here or anywhere in the server;
- the raw device id is never stored: only ``sha256(salt + device id)``, so rows from the
  same install can be grouped without anyone being able to work out which install.
  The salt comes from FEEDBACK_HASH_SALT; when that is empty a fixed per-deployment
  fallback derived from SUPABASE_URL is used (same hashes across restarts, different
  per Supabase project) and the server says so once at start-up.
"""

from __future__ import annotations

import hashlib
import logging
from typing import Any

import httpx

log = logging.getLogger("auditioner.feedback")

TABLE = "feedback"
TIMEOUT_SECONDS = 10.0
FALLBACK_SALT_PREFIX = "auditioner-feedback:"


class FeedbackStoreError(Exception):
    """Supabase did not take the row (unreachable, refused, table missing…)."""


def hash_salt(explicit: str | None, supabase_url: str | None) -> str:
    """FEEDBACK_HASH_SALT, or the fallback derived from SUPABASE_URL when it is empty."""
    salt = (explicit or "").strip()
    if salt:
        return salt
    return FALLBACK_SALT_PREFIX + (supabase_url or "").strip().rstrip("/")


def device_hash(salt: str, device_id: str) -> str:
    """sha256(salt + device id), hex. Never store the device id itself."""
    return hashlib.sha256((salt + device_id).encode("utf-8")).hexdigest()


class FeedbackStore:
    """Inserts rows into the Supabase ``feedback`` table over PostgREST.

    `transport` lets the tests plug in an ``httpx.MockTransport``; a fresh
    ``httpx.AsyncClient`` is opened per insert (feedback is rare, this keeps the
    store free of event-loop state).
    """

    def __init__(
        self,
        url: str | None,
        service_key: str | None,
        salt: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = TIMEOUT_SECONDS,
    ) -> None:
        self.url = (url or "").strip().rstrip("/")
        self._key = (service_key or "").strip()
        self.salt = hash_salt(salt, self.url)
        self.salt_is_fallback = not (salt or "").strip()
        self._transport = transport
        self.timeout = float(timeout)

    @property
    def configured(self) -> bool:
        return bool(self.url and self._key)

    @property
    def endpoint(self) -> str:
        return f"{self.url}/rest/v1/{TABLE}"

    def device_hash(self, device_id: str) -> str:
        return device_hash(self.salt, device_id)

    def __repr__(self) -> str:  # never show the key
        state = "configured" if self.configured else "off"
        return f"FeedbackStore({state}, url={self.url!r})"

    async def store(
        self,
        *,
        context: str,
        excerpt_id: str | None,
        message: str,
        app_version: str | None,
        device_id: str,
    ) -> None:
        """Insert one row. Raises FeedbackStoreError when Supabase did not accept it."""
        if not self.configured:
            raise FeedbackStoreError("feedback storage is not configured")
        row: dict[str, Any] = {
            "context": context,
            "excerpt_id": excerpt_id,
            "message": message,
            "app_version": app_version,
            "device_hash": self.device_hash(device_id),
        }
        headers = {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        }
        try:
            async with httpx.AsyncClient(transport=self._transport, timeout=self.timeout) as client:
                response = await client.post(self.endpoint, json=row, headers=headers)
        except httpx.HTTPError as exc:
            # No body, no URL details beyond the class: nothing from the row may end up in a log.
            log.warning("feedback store unreachable: %s", type(exc).__name__)
            raise FeedbackStoreError(f"request failed: {type(exc).__name__}") from exc
        if response.status_code >= 300:
            # PostgREST error bodies can quote the offending value, so only the status is logged.
            log.warning("feedback store answered %s", response.status_code)
            raise FeedbackStoreError(f"status {response.status_code}")
