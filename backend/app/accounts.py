"""Optional accounts with Sign in with Apple (PLAN B2): Skip is always possible, and the
player can delete the account in the app, which also revokes Apple's token.

The routes live in app/accounts_api.py; this module holds everything behind them:

- ``AppleClient`` checks the identity token the app got from Apple (RS256 against
  Apple's published keys, fetched with httpx and kept for 24 hours; issuer
  https://appleid.apple.com, audience = APPLE_BUNDLE_ID, not expired, and the token's
  ``nonce`` claim = sha256 hex of the raw nonce the app sends us), signs the short
  ES256 "client secret" with the Sign in with Apple key (.p8), swaps the one-time
  authorization code for a refresh token, and revokes that refresh token when the
  account is deleted.
- ``AccountStore`` reads and writes the ``accounts`` and ``account_sessions`` tables
  (supabase/migrations/20261012000000_accounts.sql) over PostgREST with the
  service-role key, exactly like app/feedback.py and app/feed.py.
- ``AccountService`` ties them together: sign in, look up a session, sign out,
  delete, and the cached look-up the scan limit uses.

What is stored, and what never is:

- Apple's user id ("sub") is never stored: only HMAC-SHA256(ACCOUNT_SECRET, sub), hex.
- Apple's refresh token is stored encrypted (Fernet; the key is derived from
  ACCOUNT_SECRET with HKDF-SHA256). It is kept only so that deleting the account can
  revoke it at Apple.
- No email and no name: the app does not ask Apple for them, and nothing here would
  keep them if it did.
- Session tokens (``secrets.token_urlsafe(32)``) go to the app once; the database
  keeps only their sha256 hex. A session not used for 365 days stops working.
- Tokens, codes, the nonce, the refresh token, the Apple id and the secrets are never
  logged: log lines carry only HTTP status codes, Apple's fixed error codes and
  exception class names.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import secrets
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
import jwt
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import load_pem_private_key

log = logging.getLogger("auditioner.accounts")

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = APPLE_ISSUER + "/auth/keys"
APPLE_TOKEN_URL = APPLE_ISSUER + "/auth/token"
APPLE_REVOKE_URL = APPLE_ISSUER + "/auth/revoke"
DEFAULT_BUNDLE_ID = "com.milaiwalker.auditioner"

JWKS_CACHE_SECONDS = 24 * 60 * 60     # Apple's public keys are kept a day
JWKS_MIN_REFRESH_SECONDS = 60.0       # Apple's keys are asked for at most once a minute (unknown key id, failed fetch)
TOKEN_LEEWAY_SECONDS = 60             # clock difference between Apple and Cloud Run
CLIENT_SECRET_SECONDS = 300           # Apple allows up to 180 days; we sign a fresh one per call
APPLE_TIMEOUT_SECONDS = 10.0
STORE_TIMEOUT_SECONDS = 10.0
SCAN_LOOKUP_TIMEOUT_SECONDS = 3.0     # a slow database must not eat a scan's time budget
SCAN_CACHE_SECONDS = 300.0            # five minutes per session token, per instance
SCAN_CACHE_MAX_ENTRIES = 10_000
SESSION_TTL = timedelta(days=365)     # unused for this long → signed out
TOUCH_EVERY = timedelta(hours=24)     # last_used_at / last_seen_at are written at most once a day
MIN_SECRET_CHARS = 32
HKDF_INFO = b"auditioner/apple-refresh-token/v1"

MAX_IDENTITY_TOKEN_CHARS = 8192
MAX_AUTH_CODE_CHARS = 1024
MAX_NONCE_CHARS = 256
# secrets.token_urlsafe(32) is 43 characters of A–Z a–z 0–9 - _
SESSION_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
# Apple's documented error codes; anything else is logged as "other" (never echoed).
APPLE_ERROR_CODES = frozenset({
    "invalid_request", "invalid_client", "invalid_grant", "unauthorized_client",
    "unsupported_grant_type", "invalid_scope", "unsupported_token_type",
})

MSG_ACCOUNTS_OFF = "Accounts aren't set up on the server yet."
MSG_SIGNED_OUT = "You're signed out. Sign in again."
MSG_BAD_APPLE_TOKEN = "Apple couldn't confirm this sign-in. Try signing in again."
MSG_APPLE_UNREACHABLE = "Couldn't reach Apple to finish signing in. Try again in a few minutes."
MSG_DELETE_APPLE_DOWN = "Couldn't reach Apple to finish deleting your account. Try again in a few minutes."
MSG_ACCOUNT_STORE = "Our account store didn't answer. Try again in a few minutes."


class AccountsOff(Exception):
    """A setting the accounts need is missing (503)."""


class AppleTokenInvalid(Exception):
    """The identity token or authorization code is bad, expired or for someone else (400)."""


class AppleUnavailable(Exception):
    """Apple could not be reached or did not answer usefully (502)."""


class AccountStoreError(Exception):
    """Supabase did not answer usefully (502)."""


class SignedOut(Exception):
    """No valid session for this token (401)."""


# ---------------------------------------------------------------------- small helpers


def sub_hash(secret: str, apple_sub: str) -> str:
    """HMAC-SHA256(ACCOUNT_SECRET, Apple's user id), hex. The only form of the id we keep."""
    return hmac.new(secret.encode("utf-8"), apple_sub.encode("utf-8"), hashlib.sha256).hexdigest()


def nonce_hash(raw_nonce: str) -> str:
    """sha256 hex of the raw nonce — what the app passed to Apple as the request's nonce."""
    return hashlib.sha256(raw_nonce.encode("utf-8")).hexdigest()


def token_hash(session_token: str) -> str:
    """sha256 hex of a session token: the only form of it the database keeps."""
    return hashlib.sha256(session_token.encode("utf-8")).hexdigest()


def new_session_token() -> str:
    return secrets.token_urlsafe(32)


def refresh_token_cipher(secret: str) -> Fernet:
    """Fernet with a key derived from ACCOUNT_SECRET (HKDF-SHA256, fixed context string)."""
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=HKDF_INFO).derive(secret.encode("utf-8"))
    return Fernet(base64.urlsafe_b64encode(key))


def load_apple_key(pem: str) -> ec.EllipticCurvePrivateKey | None:
    """The Sign in with Apple .p8 key (EC P-256), or None if the text isn't one.

    Accepts the file's text as is; a one-line copy with literal ``\\n`` is unfolded."""
    text = (pem or "").strip()
    if not text:
        return None
    if "\n" not in text and "\\n" in text:
        text = text.replace("\\n", "\n")
    try:
        key = load_pem_private_key(text.encode("utf-8"), password=None)
    except Exception:  # not PEM, encrypted, unsupported algorithm…: not a usable key
        return None
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
        return None
    return key


def bearer_token(header: str | None) -> str | None:
    """The token from ``Authorization: Bearer <token>``, or None."""
    if not header:
        return None
    scheme, _, value = header.strip().partition(" ")
    if scheme.lower() != "bearer":
        return None
    value = value.strip()
    return value or None


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def _parse_time(value: Any) -> datetime | None:
    """A PostgREST timestamptz ("2026-10-12T09:30:00.12345+00:00"), or None."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc)


def _uuid(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return None


def _apple_error(response: httpx.Response) -> str:
    """Apple's error code from a JSON error body, limited to the documented set."""
    try:
        data = response.json()
    except ValueError:
        return "other"
    code = data.get("error") if isinstance(data, dict) else None
    return code if isinstance(code, str) and code in APPLE_ERROR_CODES else "other"


# ---------------------------------------------------------------------- Apple


class AppleClient:
    """Talks to appleid.apple.com. `transport` lets the tests plug in an
    ``httpx.MockTransport``; `monotonic` lets them age the key cache."""

    def __init__(
        self,
        *,
        team_id: str,
        key_id: str,
        private_key: ec.EllipticCurvePrivateKey,
        bundle_id: str = DEFAULT_BUNDLE_ID,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = APPLE_TIMEOUT_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.team_id = team_id
        self.key_id = key_id
        self.bundle_id = bundle_id
        self._private_key = private_key
        self._transport = transport
        self.timeout = float(timeout)
        self._monotonic = monotonic
        self._keys: dict[str, jwt.PyJWK] = {}
        self._keys_fetched_at: float | None = None    # last successful fetch
        self._keys_attempted_at: float | None = None  # last attempt, successful or not

    def __repr__(self) -> str:  # never show the key
        return f"AppleClient(team={self.team_id!r}, key_id={self.key_id!r}, bundle={self.bundle_id!r})"

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=self._transport, timeout=self.timeout)

    # ---- Apple's public keys

    def _may_fetch_keys(self) -> bool:
        """At most one fetch per JWKS_MIN_REFRESH_SECONDS, counting failed attempts too:
        a flood of sign-ins while Apple is unreachable (or carrying unknown key ids)
        must not turn into a flood of requests to Apple, each waiting out a timeout."""
        attempted_at = self._keys_attempted_at
        return attempted_at is None or self._monotonic() - attempted_at >= JWKS_MIN_REFRESH_SECONDS

    async def _fetch_keys(self) -> None:
        self._keys_attempted_at = self._monotonic()
        try:
            async with self._http() as client:
                response = await client.get(APPLE_KEYS_URL, headers={"Accept": "application/json"})
        except httpx.HTTPError as exc:
            log.warning("Apple keys unreachable: %s", type(exc).__name__)
            raise AppleUnavailable("keys unreachable") from None
        if response.status_code != 200:
            log.warning("Apple keys answered %s", response.status_code)
            raise AppleUnavailable(f"keys status {response.status_code}")
        try:
            data = response.json()
        except ValueError:
            log.warning("Apple keys answer wasn't JSON")
            raise AppleUnavailable("keys not JSON") from None
        entries = data.get("keys") if isinstance(data, dict) else None
        parsed: dict[str, jwt.PyJWK] = {}
        for entry in entries if isinstance(entries, list) else []:
            if not isinstance(entry, dict) or entry.get("kty") != "RSA":
                continue
            kid = entry.get("kid")
            if not isinstance(kid, str) or not kid:
                continue
            try:
                parsed[kid] = jwt.PyJWK(entry, algorithm="RS256")
            except (jwt.PyJWKError, ValueError, TypeError, KeyError):
                continue
        if not parsed:
            log.warning("Apple keys answer had no usable key")
            raise AppleUnavailable("no usable keys")
        self._keys = parsed
        self._keys_fetched_at = self._monotonic()

    async def _key_for(self, kid: str) -> jwt.PyJWK:
        fetched_at = self._keys_fetched_at
        if fetched_at is None or self._monotonic() - fetched_at >= JWKS_CACHE_SECONDS:
            if self._may_fetch_keys():
                try:
                    await self._fetch_keys()
                except AppleUnavailable:
                    if not self._keys:
                        raise
                    # Apple's keys change rarely: yesterday's set is better than no sign-in.
                    log.warning("using Apple keys from the last successful fetch")
            elif not self._keys:
                # The last attempt (under a minute ago) failed and there is nothing to
                # fall back on: answer 502 without asking Apple again just yet.
                raise AppleUnavailable("keys unreachable (recent attempt failed)")
        key = self._keys.get(kid)
        if key is None and self._may_fetch_keys():
            await self._fetch_keys()  # Apple has rotated its keys since we last looked
            key = self._keys.get(kid)
        if key is None:
            log.info("Apple identity token refused: unknown key id")
            raise AppleTokenInvalid("unknown key id")
        return key

    # ---- the identity token

    async def verify_identity_token(self, identity_token: str, raw_nonce: str) -> str:
        """Apple's user id ("sub") from a checked identity token. Raises AppleTokenInvalid
        (or AppleUnavailable when Apple's keys can't be fetched)."""
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.PyJWTError:
            log.info("Apple identity token refused: malformed")
            raise AppleTokenInvalid("malformed") from None
        kid = header.get("kid")
        if header.get("alg") != "RS256" or not isinstance(kid, str) or not kid:
            log.info("Apple identity token refused: wrong algorithm or no key id")
            raise AppleTokenInvalid("bad header")
        key = await self._key_for(kid)
        try:
            claims = jwt.decode(
                identity_token,
                key=key.key,
                algorithms=["RS256"],
                audience=self.bundle_id,
                issuer=APPLE_ISSUER,
                leeway=TOKEN_LEEWAY_SECONDS,
                options={"require": ["iss", "aud", "exp", "iat", "sub", "nonce"]},
            )
        except jwt.PyJWTError as exc:
            log.info("Apple identity token refused: %s", type(exc).__name__)
            raise AppleTokenInvalid(type(exc).__name__) from None
        apple_sub = claims.get("sub")
        if not isinstance(apple_sub, str) or not apple_sub or len(apple_sub) > 255:
            log.info("Apple identity token refused: no usable user id")
            raise AppleTokenInvalid("bad sub")
        nonce = claims.get("nonce")
        expected = nonce_hash(raw_nonce).encode("ascii")
        if not isinstance(nonce, str) or not hmac.compare_digest(nonce.strip().lower().encode("utf-8", "surrogatepass"), expected):
            log.info("Apple identity token refused: nonce mismatch")
            raise AppleTokenInvalid("nonce mismatch")
        return apple_sub

    # ---- client secret, code exchange, revocation

    def client_secret(self) -> str:
        """The ES256 JWT Apple wants as client_secret (signed with the .p8 key)."""
        now = int(time.time())
        claims = {
            "iss": self.team_id,
            "iat": now,
            "exp": now + CLIENT_SECRET_SECONDS,
            "aud": APPLE_ISSUER,
            "sub": self.bundle_id,
        }
        return jwt.encode(claims, self._private_key, algorithm="ES256", headers={"kid": self.key_id})

    async def _post(self, url: str, form: dict[str, str], what: str) -> httpx.Response:
        try:
            async with self._http() as client:
                return await client.post(url, data=form, headers={"Accept": "application/json"})
        except httpx.HTTPError as exc:
            log.warning("Apple %s unreachable: %s", what, type(exc).__name__)
            raise AppleUnavailable(f"{what} unreachable") from None

    async def exchange_code(self, authorization_code: str, expected_sub: str) -> str:
        """Swap the one-time authorization code for a refresh token.

        An expired or already-used code is AppleTokenInvalid (400); Apple unreachable,
        refusing our client secret or answering oddly is AppleUnavailable (502)."""
        form = {
            "client_id": self.bundle_id,
            "client_secret": self.client_secret(),
            "code": authorization_code,
            "grant_type": "authorization_code",
        }
        response = await self._post(APPLE_TOKEN_URL, form, "token")
        if response.status_code != 200:
            code = _apple_error(response)
            if response.status_code == 400 and code == "invalid_grant":
                log.info("Apple refused the authorization code: invalid_grant")
                raise AppleTokenInvalid("invalid_grant")
            log.warning("Apple token endpoint answered %s (%s)", response.status_code, code)
            raise AppleUnavailable(f"token status {response.status_code}")
        try:
            data = response.json()
        except ValueError:
            log.warning("Apple token answer wasn't JSON")
            raise AppleUnavailable("token not JSON") from None
        refresh_token = data.get("refresh_token") if isinstance(data, dict) else None
        if not isinstance(refresh_token, str) or not refresh_token:
            log.warning("Apple token answer had no refresh token")
            raise AppleUnavailable("no refresh token")
        # The code must belong to the same Apple user as the identity token, or a
        # stolen identity token plus the thief's own code would bind the thief's refresh
        # token to the victim's account. Apple's answer to an authorization_code grant
        # always carries an id_token; one without it is not trusted. The id_token came
        # straight from Apple over TLS, so only its "sub" is compared.
        id_token = data.get("id_token")
        if not isinstance(id_token, str) or not id_token:
            log.warning("Apple token answer had no id_token")
            raise AppleUnavailable("no id_token")
        try:
            claims = jwt.decode(id_token, options={"verify_signature": False})
        except jwt.PyJWTError:
            log.warning("Apple token answer had an unreadable id_token")
            raise AppleUnavailable("bad id_token") from None
        code_sub = claims.get("sub")
        if not isinstance(code_sub, str) or not hmac.compare_digest(
            code_sub.encode("utf-8", "surrogatepass"), expected_sub.encode("utf-8", "surrogatepass")
        ):
            log.info("Apple authorization code belongs to a different user")
            raise AppleTokenInvalid("code for another user")
        return refresh_token

    async def revoke(self, refresh_token: str) -> None:
        """Revoke the refresh token (and with it the app's Sign in with Apple
        authorisation). Raises AppleUnavailable unless Apple confirms or says the token
        is already invalid."""
        form = {
            "client_id": self.bundle_id,
            "client_secret": self.client_secret(),
            "token": refresh_token,
            "token_type_hint": "refresh_token",
        }
        response = await self._post(APPLE_REVOKE_URL, form, "revoke")
        if response.status_code == 200:
            return
        code = _apple_error(response)
        if response.status_code == 400 and code == "invalid_grant":
            # Already revoked (e.g. the player removed the app under Apple ID settings).
            log.info("Apple says the refresh token was already invalid")
            return
        log.warning("Apple revoke answered %s (%s)", response.status_code, code)
        raise AppleUnavailable(f"revoke status {response.status_code}")


# ---------------------------------------------------------------------- Supabase


class AccountStore:
    """The ``accounts`` and ``account_sessions`` tables over PostgREST (service role).

    A fresh ``httpx.AsyncClient`` per call keeps the store free of event-loop state.
    Only status codes and exception class names are logged: PostgREST error bodies
    can quote values, and the request URLs carry token hashes."""

    def __init__(
        self,
        url: str | None,
        service_key: str | None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = STORE_TIMEOUT_SECONDS,
    ) -> None:
        self.url = (url or "").strip().rstrip("/")
        self._key = (service_key or "").strip()
        self._transport = transport
        self.timeout = float(timeout)

    @property
    def configured(self) -> bool:
        return bool(self.url and self._key)

    def __repr__(self) -> str:  # never show the key
        state = "configured" if self.configured else "off"
        return f"AccountStore({state}, url={self.url!r})"

    async def _request(
        self,
        method: str,
        table: str,
        what: str,
        *,
        params: dict[str, str] | None = None,
        body: Any = None,
        prefer: str | None = None,
        timeout: float | None = None,
    ) -> httpx.Response:
        headers = {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
            "Accept": "application/json",
        }
        if prefer:
            headers["Prefer"] = prefer
        try:
            async with httpx.AsyncClient(
                transport=self._transport, timeout=self.timeout if timeout is None else timeout
            ) as client:
                response = await client.request(
                    method, f"{self.url}/rest/v1/{table}", params=params, json=body, headers=headers
                )
        except httpx.HTTPError as exc:
            log.warning("account store unreachable (%s): %s", what, type(exc).__name__)
            raise AccountStoreError(f"{what}: {type(exc).__name__}") from None
        except Exception as exc:  # e.g. a malformed SUPABASE_URL
            log.warning("account store request failed (%s): %s", what, type(exc).__name__)
            raise AccountStoreError(f"{what}: {type(exc).__name__}") from None
        if response.status_code >= 300:
            log.warning("account store answered %s (%s)", response.status_code, what)
            raise AccountStoreError(f"{what}: status {response.status_code}")
        return response

    @staticmethod
    def _rows(response: httpx.Response, what: str) -> list[dict[str, Any]]:
        try:
            data = response.json()
        except ValueError:
            log.warning("account store answer wasn't JSON (%s)", what)
            raise AccountStoreError(f"{what}: not JSON") from None
        if not isinstance(data, list) or not all(isinstance(row, dict) for row in data):
            log.warning("account store answer wasn't a list of rows (%s)", what)
            raise AccountStoreError(f"{what}: not rows")
        return data

    async def save_account(self, apple_sub_hash: str, refresh_token_enc: str, now: datetime) -> dict[str, Any]:
        """Create the account, or update a returning player's refresh token. → {id, created_at}"""
        response = await self._request(
            "POST",
            "accounts",
            "save account",
            params={"on_conflict": "apple_sub_hash", "select": "id,created_at"},
            body={
                "apple_sub_hash": apple_sub_hash,
                "apple_refresh_token_enc": refresh_token_enc,
                "last_seen_at": _iso(now),
            },
            prefer="resolution=merge-duplicates,return=representation",
        )
        rows = self._rows(response, "save account")
        if len(rows) != 1:
            log.warning("account store returned %d rows for one account", len(rows))
            raise AccountStoreError("save account: unexpected rows")
        return rows[0]

    async def create_session(self, session_hash: str, account_id: str) -> None:
        await self._request(
            "POST",
            "account_sessions",
            "create session",
            body={"token_hash": session_hash, "account_id": account_id},
            prefer="return=minimal",
        )

    async def find_session(self, session_hash: str, *, timeout: float | None = None) -> dict[str, Any] | None:
        response = await self._request(
            "GET",
            "account_sessions",
            "find session",
            params={"token_hash": f"eq.{session_hash}", "select": "account_id,last_used_at", "limit": "1"},
            timeout=timeout,
        )
        rows = self._rows(response, "find session")
        return rows[0] if rows else None

    async def find_account(
        self, account_id: str, *, with_refresh_token: bool = False, timeout: float | None = None
    ) -> dict[str, Any] | None:
        columns = "id,created_at,apple_refresh_token_enc" if with_refresh_token else "id,created_at"
        response = await self._request(
            "GET",
            "accounts",
            "find account",
            params={"id": f"eq.{account_id}", "select": columns, "limit": "1"},
            timeout=timeout,
        )
        rows = self._rows(response, "find account")
        return rows[0] if rows else None

    async def touch(self, session_hash: str, account_id: str, now: datetime, *, timeout: float | None = None) -> None:
        stamp = _iso(now)
        await self._request(
            "PATCH",
            "account_sessions",
            "touch session",
            params={"token_hash": f"eq.{session_hash}"},
            body={"last_used_at": stamp},
            prefer="return=minimal",
            timeout=timeout,
        )
        await self._request(
            "PATCH",
            "accounts",
            "touch account",
            params={"id": f"eq.{account_id}"},
            body={"last_seen_at": stamp},
            prefer="return=minimal",
            timeout=timeout,
        )

    async def delete_session(self, session_hash: str) -> None:
        await self._request(
            "DELETE", "account_sessions", "delete session",
            params={"token_hash": f"eq.{session_hash}"}, prefer="return=minimal",
        )

    async def delete_account(self, account_id: str) -> None:
        """Deletes the account; its sessions go with it (on delete cascade)."""
        await self._request(
            "DELETE", "accounts", "delete account",
            params={"id": f"eq.{account_id}"}, prefer="return=minimal",
        )

    async def delete_unused_sessions(self, cutoff: datetime) -> None:
        await self._request(
            "DELETE", "account_sessions", "delete unused sessions",
            params={"last_used_at": f"lt.{_iso(cutoff)}"}, prefer="return=minimal",
        )


# ---------------------------------------------------------------------- the service


def _missing_settings(settings: Any) -> list[str]:
    pairs = (
        ("APPLE_TEAM_ID", settings.apple_team_id),
        ("APPLE_KEY_ID", settings.apple_key_id),
        ("APPLE_PRIVATE_KEY", settings.apple_private_key),
        ("ACCOUNT_SECRET", settings.account_secret),
        ("SUPABASE_URL", settings.supabase_url),
        ("SUPABASE_SERVICE_ROLE_KEY", settings.supabase_service_role_key),
    )
    return [name for name, value in pairs if not (value or "").strip()]


class AccountService:
    """Sign in, look up, sign out, delete; plus the cached look-up for the scan limit.

    `problems` lists what is missing or unusable in the settings (names only, never
    values); while it is not empty every call raises AccountsOff (503)."""

    def __init__(
        self,
        *,
        apple: AppleClient | None,
        store: AccountStore,
        secret: str,
        daily_scan_limit: int,
        problems: list[str] | None = None,
        clock: Callable[[], datetime] = _utc_now,
        monotonic: Callable[[], float] = time.monotonic,
        scan_cache_seconds: float = SCAN_CACHE_SECONDS,
    ) -> None:
        self.apple = apple
        self.store = store
        self._secret = secret or ""
        self.daily_scan_limit = int(daily_scan_limit)
        self.problems: list[str] = list(problems or [])
        if apple is None and not self.problems:
            self.problems.append("Sign in with Apple settings")
        if not store.configured and not self.problems:
            self.problems.append("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY")
        if len(self._secret) < MIN_SECRET_CHARS and not self.problems:
            self.problems.append("ACCOUNT_SECRET")
        self._cipher: Fernet | None = refresh_token_cipher(self._secret) if self._secret else None
        self._clock = clock
        self._monotonic = monotonic
        self.scan_cache_seconds = float(scan_cache_seconds)
        self._scan_cache: OrderedDict[str, tuple[float, str | None]] = OrderedDict()

    @classmethod
    def from_settings(
        cls,
        settings: Any,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], datetime] = _utc_now,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> "AccountService":
        problems = _missing_settings(settings)
        secret = (settings.account_secret or "").strip()
        if secret and len(secret) < MIN_SECRET_CHARS:
            problems.append(f"ACCOUNT_SECRET (shorter than {MIN_SECRET_CHARS} characters)")
        apple: AppleClient | None = None
        if (settings.apple_private_key or "").strip():
            private_key = load_apple_key(settings.apple_private_key)
            if private_key is None:
                problems.append("APPLE_PRIVATE_KEY (not a Sign in with Apple .p8 key)")
            elif (settings.apple_team_id or "").strip() and (settings.apple_key_id or "").strip():
                apple = AppleClient(
                    team_id=settings.apple_team_id.strip(),
                    key_id=settings.apple_key_id.strip(),
                    private_key=private_key,
                    bundle_id=(settings.apple_bundle_id or "").strip() or DEFAULT_BUNDLE_ID,
                    transport=transport,
                    monotonic=monotonic,
                )
        store = AccountStore(settings.supabase_url, settings.supabase_service_role_key, transport=transport)
        return cls(
            apple=apple,
            store=store,
            secret=secret,
            daily_scan_limit=settings.signed_in_daily_scan_limit,
            problems=problems,
            clock=clock,
            monotonic=monotonic,
        )

    @property
    def configured(self) -> bool:
        return not self.problems

    def __repr__(self) -> str:  # never show the secret
        state = "configured" if self.configured else "off"
        return f"AccountService({state}, apple={self.apple!r}, store={self.store!r})"

    def _require(self) -> tuple[AppleClient, Fernet]:
        if self.problems or self.apple is None or self._cipher is None:
            raise AccountsOff(", ".join(self.problems))
        return self.apple, self._cipher

    # ---- sign in

    async def sign_in(self, identity_token: str, authorization_code: str, raw_nonce: str) -> dict[str, Any]:
        """Check Apple's token, swap the code, store the account, open a session.
        → {"accountId", "sessionToken", "dailyScanLimit"}. Nothing is stored unless
        Apple confirmed the player and gave us a refresh token."""
        apple, cipher = self._require()
        apple_sub = await apple.verify_identity_token(identity_token, raw_nonce)
        refresh_token = await apple.exchange_code(authorization_code, apple_sub)
        now = self._clock()
        row = await self.store.save_account(
            sub_hash(self._secret, apple_sub),
            cipher.encrypt(refresh_token.encode("utf-8")).decode("ascii"),
            now,
        )
        account_id = _uuid(row.get("id"))
        if account_id is None:
            log.warning("account store returned an account without a usable id")
            raise AccountStoreError("save account: no id")
        session_token = new_session_token()
        await self.store.create_session(token_hash(session_token), account_id)
        try:  # housekeeping, best effort: sessions unused for a year are gone for good
            await self.store.delete_unused_sessions(now - SESSION_TTL)
        except AccountStoreError:
            pass
        log.info("account signed in")
        return {"accountId": account_id, "sessionToken": session_token, "dailyScanLimit": self.daily_scan_limit}

    # ---- sessions

    async def _authenticate(
        self, session_token: str | None, *, touch: bool = True, timeout: float | None = None
    ) -> tuple[str, str]:
        """(account id, token hash) for a live session, or SignedOut."""
        self._require()
        if not session_token or not SESSION_TOKEN_PATTERN.match(session_token):
            raise SignedOut()
        session_hash = token_hash(session_token)
        row = await self.store.find_session(session_hash, timeout=timeout)
        if row is None:
            raise SignedOut()
        account_id = _uuid(row.get("account_id"))
        if account_id is None:
            raise SignedOut()
        now = self._clock()
        last_used = _parse_time(row.get("last_used_at"))
        if last_used is not None and now - last_used > SESSION_TTL:
            try:
                await self.store.delete_session(session_hash)
            except AccountStoreError:
                pass
            self._forget(session_hash)
            raise SignedOut()
        if touch and (last_used is None or now - last_used > TOUCH_EVERY):
            try:  # keeps the session alive; never worth failing a request for
                await self.store.touch(session_hash, account_id, now, timeout=timeout)
            except AccountStoreError:
                pass
        return account_id, session_hash

    async def account(self, session_token: str | None) -> dict[str, Any]:
        """→ {"accountId", "dailyScanLimit", "createdAt": "YYYY-MM-DD"}"""
        account_id, _ = await self._authenticate(session_token)
        row = await self.store.find_account(account_id)
        if row is None:
            raise SignedOut()
        created = _parse_time(row.get("created_at"))
        if created is None:
            log.warning("account row without a readable created_at")
            raise AccountStoreError("find account: bad created_at")
        return {
            "accountId": account_id,
            "dailyScanLimit": self.daily_scan_limit,
            "createdAt": created.date().isoformat(),
        }

    async def sign_out(self, session_token: str | None) -> None:
        """Ends this one session; the account and its other sessions stay."""
        _, session_hash = await self._authenticate(session_token, touch=False)
        await self.store.delete_session(session_hash)
        self._forget(session_hash)
        log.info("account session signed out")

    async def delete(self, session_token: str | None) -> None:
        """Revoke Apple's token, then delete the account and every session.
        If Apple can't be reached nothing is deleted (AppleUnavailable)."""
        apple, cipher = self._require()
        account_id, _ = await self._authenticate(session_token, touch=False)
        row = await self.store.find_account(account_id, with_refresh_token=True)
        if row is None:
            raise SignedOut()
        encrypted = row.get("apple_refresh_token_enc")
        refresh_token: str | None = None
        if isinstance(encrypted, str) and encrypted:
            try:
                refresh_token = cipher.decrypt(encrypted.encode("ascii")).decode("utf-8")
            except (InvalidToken, ValueError, UnicodeError):
                refresh_token = None
        if refresh_token is None:
            # Only possible if ACCOUNT_SECRET changed. The token can never be revoked by
            # us now; the player's right to delete the account still comes first.
            log.warning("stored Apple token unreadable (was ACCOUNT_SECRET changed?); deleting without revoking")
        else:
            await apple.revoke(refresh_token)
        await self.store.delete_account(account_id)
        self._forget_account(account_id)
        log.info("account deleted")

    # ---- the scan limit

    def _forget(self, session_hash: str) -> None:
        self._scan_cache.pop(session_hash, None)

    def _forget_account(self, account_id: str) -> None:
        for key in [k for k, (_, value) in self._scan_cache.items() if value == account_id]:
            del self._scan_cache[key]

    def clear_cache(self) -> None:
        self._scan_cache.clear()

    async def scan_account(self, session_token: str | None) -> str | None:
        """The account id for a scan's Bearer token, or None (no token, unknown or
        expired token, accounts off, database slow or down). Never raises: a bad token
        only means the scan counts against the device limit instead. Answers are kept
        for five minutes per token on this instance."""
        try:
            if not self.configured or not session_token or not SESSION_TOKEN_PATTERN.match(session_token):
                return None
            session_hash = token_hash(session_token)
            now = self._monotonic()
            cached = self._scan_cache.get(session_hash)
            if cached is not None:
                expires_at, value = cached
                if now < expires_at:
                    self._scan_cache.move_to_end(session_hash)
                    return value
                del self._scan_cache[session_hash]
            try:
                account_id: str | None
                account_id, _ = await self._authenticate(session_token, timeout=SCAN_LOOKUP_TIMEOUT_SECONDS)
            except SignedOut:
                account_id = None
            self._scan_cache[session_hash] = (self._monotonic() + self.scan_cache_seconds, account_id)
            self._scan_cache.move_to_end(session_hash)
            while len(self._scan_cache) > SCAN_CACHE_MAX_ENTRIES:
                self._scan_cache.popitem(last=False)
            return account_id
        except Exception as exc:  # store down, timeout, anything: fall back to the device limit
            log.warning("account look-up for a scan failed (%s); using the device limit", type(exc).__name__)
            return None


__all__ = [
    "APPLE_ISSUER",
    "APPLE_KEYS_URL",
    "APPLE_REVOKE_URL",
    "APPLE_TOKEN_URL",
    "AccountService",
    "AccountStore",
    "AccountStoreError",
    "AccountsOff",
    "AppleClient",
    "AppleTokenInvalid",
    "AppleUnavailable",
    "MSG_ACCOUNTS_OFF",
    "MSG_ACCOUNT_STORE",
    "MSG_APPLE_UNREACHABLE",
    "MSG_BAD_APPLE_TOKEN",
    "MSG_DELETE_APPLE_DOWN",
    "MSG_SIGNED_OUT",
    "SignedOut",
    "bearer_token",
    "load_apple_key",
    "new_session_token",
    "nonce_hash",
    "refresh_token_cipher",
    "sub_hash",
    "token_hash",
]
