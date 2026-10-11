"""Sign in with Apple accounts (/v1/account…) and the signed-in scan limit, against a
fake Apple and a fake Supabase on one httpx.MockTransport — no network.

Every key is generated here at test time (an RSA key per fake Apple signing key, an
EC P-256 key standing in for the .p8); no key material is committed."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Any, Callable
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from fastapi.testclient import TestClient

from app.accounts import (
    APPLE_ISSUER,
    MSG_ACCOUNT_STORE,
    MSG_ACCOUNTS_OFF,
    MSG_APPLE_UNREACHABLE,
    MSG_BAD_APPLE_TOKEN,
    MSG_DELETE_APPLE_DOWN,
    MSG_SIGNED_OUT,
    AccountService,
    bearer_token,
    load_apple_key,
    refresh_token_cipher,
)
from app.config import Settings
from app.main import create_app
from conftest import DEVICE, post_omr

TEAM_ID = "TEAM123456"
KEY_ID = "KEY7654321"
BUNDLE_ID = "com.milaiwalker.auditioner"
SUPABASE_HOST = "accounts-test.supabase.co"
SUPABASE_URL = f"https://{SUPABASE_HOST}"
SERVICE_KEY = "service-role-key-for-account-tests"
ACCOUNT_SECRET = "account-secret-for-tests-" + "Q" * 24
APPLE_SUB = "001234.fakeapplesubject0001.0042"
OTHER_SUB = "009876.fakeapplesubject0002.0042"
RAW_NONCE = "raw-nonce-WOMBAT-3141"


# ---------------------------------------------------------------------- keys


@lru_cache(maxsize=None)
def rsa_key(name: str) -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@lru_cache(maxsize=None)
def ec_key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def ec_pem() -> str:
    return ec_key().private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode("ascii")


def jwk_for(kid: str) -> dict[str, Any]:
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(rsa_key(kid).public_key()))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return jwk


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------- fake Apple


class FakeApple:
    def __init__(self) -> None:
        self.published: list[str] = ["kid-a"]
        self.codes: dict[str, str] = {}
        self.refresh_tokens: dict[str, str] = {}
        self.revoked: list[str] = []
        self.down: set[str] = set()          # "keys", "token", "revoke" → connection error
        self.status: dict[str, int] = {}     # endpoint → forced status
        self.error: dict[str, str] = {}      # endpoint → forced error code
        self.calls: dict[str, int] = {"keys": 0, "token": 0, "revoke": 0}
        self.client_secrets: list[str] = []
        self.id_token_sub: str | None = None  # make /auth/token answer for someone else

    def identity_token(
        self,
        *,
        sub: str = APPLE_SUB,
        nonce: str | None = RAW_NONCE,
        aud: str = BUNDLE_ID,
        iss: str = APPLE_ISSUER,
        expires_in: int = 600,
        kid: str = "kid-a",
        signing_kid: str | None = None,
    ) -> str:
        now = int(datetime.now(timezone.utc).timestamp())
        claims: dict[str, Any] = {
            "iss": iss,
            "aud": aud,
            "exp": now + expires_in,
            "iat": now - 5 if expires_in > 0 else now + expires_in - 600,
            "sub": sub,
            "auth_time": now - 5,
            "nonce_supported": True,
        }
        if nonce is not None:
            claims["nonce"] = sha256_hex(nonce)
        return jwt.encode(claims, rsa_key(signing_kid or kid), algorithm="RS256", headers={"kid": kid})

    def issue_code(self, sub: str = APPLE_SUB) -> str:
        code = "c" + secrets.token_hex(12)
        self.codes[code] = sub
        return code

    def _client_secret_ok(self, value: str) -> bool:
        self.client_secrets.append(value)
        try:
            header = jwt.get_unverified_header(value)
            claims = jwt.decode(
                value, ec_key().public_key(), algorithms=["ES256"], audience=APPLE_ISSUER, issuer=TEAM_ID
            )
        except jwt.PyJWTError:
            return False
        return (
            header.get("kid") == KEY_ID
            and claims.get("sub") == BUNDLE_ID
            and claims["exp"] - claims["iat"] <= 180 * 24 * 3600
        )

    def _forced(self, what: str) -> httpx.Response | None:
        if what in self.down:
            raise httpx.ConnectError("Apple is down (test)")
        if what in self.status:
            body = {"error": self.error[what]} if what in self.error else {}
            return httpx.Response(self.status[what], json=body)
        return None

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/auth/keys" and request.method == "GET":
            self.calls["keys"] += 1
            forced = self._forced("keys")
            if forced is not None:
                return forced
            return httpx.Response(200, json={"keys": [jwk_for(kid) for kid in self.published]})
        form = {k: v[0] for k, v in parse_qs(request.content.decode("utf-8")).items()}
        if path == "/auth/token" and request.method == "POST":
            self.calls["token"] += 1
            forced = self._forced("token")
            if forced is not None:
                return forced
            if form.get("client_id") != BUNDLE_ID or not self._client_secret_ok(form.get("client_secret", "")):
                return httpx.Response(400, json={"error": "invalid_client"})
            if form.get("grant_type") != "authorization_code":
                return httpx.Response(400, json={"error": "unsupported_grant_type"})
            sub = self.codes.pop(form.get("code", ""), None)
            if sub is None:
                return httpx.Response(400, json={"error": "invalid_grant"})
            refresh = "r" + secrets.token_hex(16)
            self.refresh_tokens[refresh] = sub
            now = int(datetime.now(timezone.utc).timestamp())
            id_token = jwt.encode(
                {"iss": APPLE_ISSUER, "aud": BUNDLE_ID, "sub": self.id_token_sub or sub, "iat": now, "exp": now + 600},
                rsa_key("kid-a"),
                algorithm="RS256",
                headers={"kid": "kid-a"},
            )
            return httpx.Response(
                200,
                json={
                    "access_token": "a" + secrets.token_hex(8),
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "refresh_token": refresh,
                    "id_token": id_token,
                },
            )
        if path == "/auth/revoke" and request.method == "POST":
            self.calls["revoke"] += 1
            forced = self._forced("revoke")
            if forced is not None:
                return forced
            if form.get("client_id") != BUNDLE_ID or not self._client_secret_ok(form.get("client_secret", "")):
                return httpx.Response(400, json={"error": "invalid_client"})
            if form.get("token_type_hint") != "refresh_token":
                return httpx.Response(400, json={"error": "invalid_request"})
            self.revoked.append(form.get("token", ""))
            return httpx.Response(200)
        return httpx.Response(404)


# ---------------------------------------------------------------------- fake Supabase


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class FakeSupabase:
    """Just enough PostgREST for app/accounts.py: eq/lt filters, select, upsert, cascade."""

    def __init__(self) -> None:
        self.accounts: dict[str, dict[str, Any]] = {}
        self.sessions: dict[str, dict[str, Any]] = {}
        self.down = False
        self.requests: list[tuple[str, str]] = []

    def count(self, method: str, table: str) -> int:
        return sum(1 for m, t in self.requests if m == method and t == table)

    @staticmethod
    def _pick(row: dict[str, Any], select: str | None) -> dict[str, Any]:
        if not select:
            return dict(row)
        return {col: row.get(col) for col in select.split(",")}

    @staticmethod
    def _matches(row: dict[str, Any], params: dict[str, str]) -> bool:
        for col, cond in params.items():
            if col in ("select", "limit", "on_conflict"):
                continue
            op, _, value = cond.partition(".")
            if op == "eq" and str(row.get(col)) != value:
                return False
            if op == "lt" and not (datetime.fromisoformat(row[col]) < datetime.fromisoformat(value)):
                return False
        return True

    def handle(self, request: httpx.Request) -> httpx.Response:
        assert request.headers.get("apikey") == SERVICE_KEY
        assert request.headers.get("authorization") == f"Bearer {SERVICE_KEY}"
        if self.down:
            raise httpx.ConnectError("Supabase is down (test)")
        table = request.url.path.rsplit("/", 1)[-1]
        params = dict(request.url.params)
        self.requests.append((request.method, table))
        rows = self.accounts if table == "accounts" else self.sessions
        key_col = "id" if table == "accounts" else "token_hash"
        body = json.loads(request.content) if request.content else None

        if request.method == "GET":
            found = [self._pick(r, params.get("select")) for r in rows.values() if self._matches(r, params)]
            return httpx.Response(200, json=found[: int(params.get("limit", "1000"))])

        if request.method == "POST" and table == "accounts":
            assert params.get("on_conflict") == "apple_sub_hash"
            assert "resolution=merge-duplicates" in request.headers.get("prefer", "")
            existing = next((r for r in rows.values() if r["apple_sub_hash"] == body["apple_sub_hash"]), None)
            if existing is None:
                existing = {"id": str(uuid.uuid4()), "created_at": _now_iso(), **body}
                rows[existing["id"]] = existing
            else:
                existing.update(body)
            return httpx.Response(201, json=[self._pick(existing, params.get("select"))])

        if request.method == "POST" and table == "account_sessions":
            if body["account_id"] not in self.accounts or body["token_hash"] in rows:
                return httpx.Response(409, json={"message": "conflict"})
            rows[body["token_hash"]] = {**body, "created_at": _now_iso(), "last_used_at": _now_iso()}
            return httpx.Response(201)

        if request.method == "PATCH":
            for row in rows.values():
                if self._matches(row, params):
                    row.update(body)
            return httpx.Response(204)

        if request.method == "DELETE":
            for key in [k for k, r in rows.items() if self._matches(r, params)]:
                del rows[key]
                if table == "accounts":  # on delete cascade
                    for token in [t for t, s in self.sessions.items() if s["account_id"] == key]:
                        del self.sessions[token]
            return httpx.Response(204)

        return httpx.Response(405)


# ---------------------------------------------------------------------- the world


class Clock:
    def __init__(self) -> None:
        self.now = 1_000.0

    def __call__(self) -> float:
        return self.now


class World:
    def __init__(self, settings: Settings) -> None:
        self.apple = FakeApple()
        self.supabase = FakeSupabase()
        self.clock = Clock()
        self.settings = settings
        self.app = create_app(settings)

        def route(request: httpx.Request) -> httpx.Response:
            if request.url.host == "appleid.apple.com":
                return self.apple.handle(request)
            if request.url.host == SUPABASE_HOST:
                return self.supabase.handle(request)
            return httpx.Response(404)

        self.service = AccountService.from_settings(
            settings, transport=httpx.MockTransport(route), monotonic=self.clock
        )
        self.app.state.accounts = self.service
        self.client = TestClient(self.app)

    def sign_in(self, **token_args: Any) -> httpx.Response:
        sub = token_args.get("sub", APPLE_SUB)
        body = {
            "identityToken": self.apple.identity_token(**token_args),
            "authorizationCode": self.apple.issue_code(sub),
            "nonce": RAW_NONCE,
        }
        return self.client.post("/v1/account/apple", json=body)

    def session(self) -> str:
        response = self.sign_in()
        assert response.status_code == 200, response.text
        return response.json()["sessionToken"]


def account_settings(**overrides: Any) -> dict[str, Any]:
    values: dict[str, Any] = {
        "apple_team_id": TEAM_ID,
        "apple_key_id": KEY_ID,
        "apple_private_key": ec_pem(),
        "apple_bundle_id": BUNDLE_ID,
        "account_secret": ACCOUNT_SECRET,
        "supabase_url": SUPABASE_URL,
        "supabase_service_role_key": SERVICE_KEY,
        "signed_in_daily_scan_limit": 60,
    }
    values.update(overrides)
    return values


@pytest.fixture
def world_factory(settings_factory: Callable[..., Settings]) -> Callable[..., World]:
    def factory(**overrides: Any) -> World:
        return World(settings_factory(**account_settings(**overrides)))

    return factory


@pytest.fixture
def world(world_factory: Callable[..., World]) -> World:
    return world_factory()


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------- sign in


def test_sign_in_happy_path(world: World) -> None:
    response = world.sign_in()

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"accountId", "sessionToken", "dailyScanLimit"}
    assert str(uuid.UUID(body["accountId"])) == body["accountId"]
    assert body["dailyScanLimit"] == 60
    assert len(body["sessionToken"]) >= 43
    assert response.headers["cache-control"] == "no-store"

    # One account: hashed Apple id, encrypted refresh token, nothing else about the person.
    [row] = world.supabase.accounts.values()
    assert row["apple_sub_hash"] == hmac.new(ACCOUNT_SECRET.encode(), APPLE_SUB.encode(), hashlib.sha256).hexdigest()
    assert APPLE_SUB not in json.dumps(row)
    [refresh] = world.apple.refresh_tokens
    assert refresh not in json.dumps(row)
    assert refresh_token_cipher(ACCOUNT_SECRET).decrypt(row["apple_refresh_token_enc"].encode()).decode() == refresh
    assert set(row) == {"id", "created_at", "apple_sub_hash", "apple_refresh_token_enc", "last_seen_at"}

    # One session, stored as sha256 of the token only.
    [(stored_hash, session)] = world.supabase.sessions.items()
    assert stored_hash == sha256_hex(body["sessionToken"])
    assert session["account_id"] == body["accountId"]
    assert body["sessionToken"] not in json.dumps(world.supabase.sessions)

    # Apple got a valid ES256 client secret (FakeApple checked it) for the code exchange.
    assert world.apple.calls["token"] == 1
    secret_header = jwt.get_unverified_header(world.apple.client_secrets[0])
    assert secret_header["alg"] == "ES256" and secret_header["kid"] == KEY_ID


def test_returning_player_keeps_the_same_account(world: World) -> None:
    first = world.sign_in().json()
    second = world.sign_in().json()

    assert first["accountId"] == second["accountId"]
    assert first["sessionToken"] != second["sessionToken"]
    assert len(world.supabase.accounts) == 1
    assert len(world.supabase.sessions) == 2
    # The newest refresh token is the one kept (it is the one revoked on deletion).
    [row] = world.supabase.accounts.values()
    newest = list(world.apple.refresh_tokens)[-1]
    assert refresh_token_cipher(ACCOUNT_SECRET).decrypt(row["apple_refresh_token_enc"].encode()).decode() == newest


@pytest.mark.parametrize(
    "token_args",
    [
        pytest.param({"aud": "com.someone.else"}, id="wrong-audience"),
        pytest.param({"iss": "https://appleid.example.com"}, id="wrong-issuer"),
        pytest.param({"iss": "https://appleid.apple.com.evil"}, id="issuer-prefix"),
        pytest.param({"expires_in": -3600}, id="expired"),
        pytest.param({"nonce": "a-different-nonce"}, id="nonce-mismatch"),
        pytest.param({"nonce": None}, id="no-nonce"),
        pytest.param({"signing_kid": "kid-impostor"}, id="signed-by-someone-else"),
    ],
)
def test_bad_identity_tokens_are_refused_and_nothing_is_stored(world: World, token_args: dict[str, Any]) -> None:
    response = world.sign_in(**token_args)

    assert response.status_code == 400, response.text
    assert response.json() == {"detail": MSG_BAD_APPLE_TOKEN}
    assert world.apple.calls["token"] == 0  # the code is never even exchanged
    assert world.supabase.accounts == {} and world.supabase.sessions == {}


def test_raw_nonce_must_hash_to_the_token_nonce(world: World) -> None:
    body = {
        "identityToken": world.apple.identity_token(),
        "authorizationCode": world.apple.issue_code(),
        "nonce": sha256_hex(RAW_NONCE),  # the hash instead of the raw nonce
    }
    response = world.client.post("/v1/account/apple", json=body)
    assert response.status_code == 400
    assert world.supabase.accounts == {}


@pytest.mark.parametrize("token", ["not-a-jwt", "a.b.c", ""])
def test_malformed_identity_token(world: World, token: str) -> None:
    body = {"identityToken": token, "authorizationCode": world.apple.issue_code(), "nonce": RAW_NONCE}
    response = world.client.post("/v1/account/apple", json=body)
    assert response.status_code in (400, 422)
    assert set(response.json()) == {"detail"}
    assert world.supabase.accounts == {}


def test_non_ascii_request_fields_are_422(world: World) -> None:
    body = {
        "identityToken": world.apple.identity_token(),
        "authorizationCode": world.apple.issue_code(),
        "nonce": "nonce-été",
    }
    response = world.client.post("/v1/account/apple", json=body)
    assert response.status_code == 422
    assert set(response.json()) == {"detail"}


def test_non_ascii_nonce_claim_is_400_not_500(world: World) -> None:
    now = int(datetime.now(timezone.utc).timestamp())
    token = jwt.encode(
        {"iss": APPLE_ISSUER, "aud": BUNDLE_ID, "sub": APPLE_SUB, "nonce": "ééé", "iat": now, "exp": now + 600},
        rsa_key("kid-a"),
        algorithm="RS256",
        headers={"kid": "kid-a"},
    )
    body = {"identityToken": token, "authorizationCode": world.apple.issue_code(), "nonce": RAW_NONCE}
    response = world.client.post("/v1/account/apple", json=body)
    assert response.status_code == 400
    assert response.json() == {"detail": MSG_BAD_APPLE_TOKEN}


def test_hs256_token_is_refused(world: World) -> None:
    forged = jwt.encode(
        {"iss": APPLE_ISSUER, "aud": BUNDLE_ID, "sub": APPLE_SUB, "nonce": sha256_hex(RAW_NONCE),
         "iat": 1, "exp": 4_000_000_000},
        "shared-secret-that-apple-never-uses-000000",
        algorithm="HS256",
        headers={"kid": "kid-a"},
    )
    body = {"identityToken": forged, "authorizationCode": world.apple.issue_code(), "nonce": RAW_NONCE}
    assert world.client.post("/v1/account/apple", json=body).status_code == 400


def test_apple_keys_are_cached_for_a_day(world: World) -> None:
    assert world.sign_in().status_code == 200
    assert world.sign_in().status_code == 200
    assert world.apple.calls["keys"] == 1

    world.clock.now += 24 * 3600 + 1
    assert world.sign_in().status_code == 200
    assert world.apple.calls["keys"] == 2


def test_apple_key_rotation_is_picked_up(world: World) -> None:
    assert world.sign_in().status_code == 200
    assert world.apple.calls["keys"] == 1

    world.apple.published = ["kid-b"]  # Apple rotates its signing key
    world.clock.now += 120
    response = world.sign_in(kid="kid-b")
    assert response.status_code == 200, response.text
    assert world.apple.calls["keys"] == 2

    # An unknown key id right after a fetch does not make us hammer Apple.
    assert world.sign_in(kid="kid-z").status_code == 400
    assert world.apple.calls["keys"] == 2


def test_apple_keys_unreachable_is_502(world: World) -> None:
    world.apple.down.add("keys")
    response = world.sign_in()
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_APPLE_UNREACHABLE}
    assert world.supabase.accounts == {}


def test_stale_apple_keys_are_used_when_apple_is_down(world: World) -> None:
    assert world.sign_in().status_code == 200
    world.clock.now += 24 * 3600 + 1
    world.apple.down.add("keys")
    assert world.sign_in().status_code == 200


# ---------------------------------------------------------------------- code exchange


@pytest.mark.parametrize(
    "break_apple",
    [
        pytest.param(lambda a: a.down.add("token"), id="unreachable"),
        pytest.param(lambda a: a.status.update(token=500), id="server-error"),
        pytest.param(lambda a: (a.status.update(token=400), a.error.update(token="invalid_client")), id="invalid-client"),
        pytest.param(lambda a: a.status.update(token=200), id="no-refresh-token"),
    ],
)
def test_code_exchange_failure_is_502_and_nothing_is_stored(world: World, break_apple: Callable[[FakeApple], Any]) -> None:
    break_apple(world.apple)
    response = world.sign_in()

    assert response.status_code == 502, response.text
    assert response.json() == {"detail": MSG_APPLE_UNREACHABLE}
    assert world.supabase.accounts == {} and world.supabase.sessions == {}
    assert world.supabase.requests == []


def test_expired_or_used_code_is_400_and_nothing_is_stored(world: World) -> None:
    body = {"identityToken": world.apple.identity_token(), "authorizationCode": "never-issued", "nonce": RAW_NONCE}
    response = world.client.post("/v1/account/apple", json=body)

    assert response.status_code == 400
    assert response.json() == {"detail": MSG_BAD_APPLE_TOKEN}
    assert world.supabase.accounts == {}


def test_code_for_another_apple_user_is_refused(world: World) -> None:
    world.apple.id_token_sub = OTHER_SUB
    response = world.sign_in()
    assert response.status_code == 400
    assert world.supabase.accounts == {}


def test_account_store_down_on_sign_in_is_502(world: World) -> None:
    world.supabase.down = True
    response = world.sign_in()
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_ACCOUNT_STORE}


# ---------------------------------------------------------------------- not configured


@pytest.mark.parametrize(
    "overrides",
    [
        pytest.param({"apple_team_id": ""}, id="no-team-id"),
        pytest.param({"apple_key_id": ""}, id="no-key-id"),
        pytest.param({"apple_private_key": ""}, id="no-private-key"),
        pytest.param({"account_secret": ""}, id="no-account-secret"),
        pytest.param({"supabase_url": ""}, id="no-supabase-url"),
        pytest.param({"supabase_service_role_key": ""}, id="no-supabase-key"),
        pytest.param({"apple_private_key": "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----"}, id="bad-key"),
        pytest.param({"account_secret": "too-short"}, id="short-secret"),
    ],
)
def test_503_when_accounts_are_not_set_up(world_factory: Callable[..., World], overrides: dict[str, Any]) -> None:
    world = world_factory(**overrides)
    off = {"detail": MSG_ACCOUNTS_OFF}

    response = world.sign_in()
    assert (response.status_code, response.json()) == (503, off)
    token = "t" * 43
    for method, path in (("GET", "/v1/account"), ("POST", "/v1/account/signout"), ("DELETE", "/v1/account")):
        response = world.client.request(method, path, headers=bearer(token))
        assert (response.status_code, response.json()) == (503, off), (method, path)
    assert world.apple.calls == {"keys": 0, "token": 0, "revoke": 0}
    assert world.supabase.requests == []


def test_default_settings_have_accounts_off(client: TestClient) -> None:
    response = client.get("/v1/account", headers=bearer("t" * 43))
    assert response.status_code == 503
    assert response.json() == {"detail": MSG_ACCOUNTS_OFF}


def test_settings_from_env() -> None:
    env = {
        "APPLE_TEAM_ID": " TEAM123456 ",
        "APPLE_KEY_ID": "KEY7654321",
        "APPLE_PRIVATE_KEY": ec_pem(),
        "ACCOUNT_SECRET": ACCOUNT_SECRET,
        "SIGNED_IN_DAILY_SCAN_LIMIT": "75",
    }
    settings = Settings.from_env(env)
    assert settings.apple_team_id == "TEAM123456"
    assert settings.apple_bundle_id == "com.milaiwalker.auditioner"
    assert settings.signed_in_daily_scan_limit == 75
    assert Settings.from_env({}).signed_in_daily_scan_limit == 60
    # Secrets never show up when settings are printed.
    shown = repr(settings)
    assert ACCOUNT_SECRET not in shown and "PRIVATE KEY" not in shown


def test_p8_key_loading() -> None:
    pem = ec_pem()
    assert load_apple_key(pem) is not None
    assert load_apple_key(pem.replace("\n", "\\n")) is not None  # pasted as one line
    assert load_apple_key("") is None
    assert load_apple_key("not a key") is None
    rsa_pem = rsa_key("kid-a").private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    assert load_apple_key(rsa_pem) is None  # Sign in with Apple keys are EC P-256


def test_bearer_header_parsing() -> None:
    assert bearer_token("Bearer abc") == "abc"
    assert bearer_token("bearer   abc ") == "abc"
    assert bearer_token("Basic abc") is None
    assert bearer_token("Bearer") is None
    assert bearer_token(None) is None


# ---------------------------------------------------------------------- GET / signout / DELETE


def test_get_account(world: World) -> None:
    signed_in = world.sign_in().json()
    response = world.client.get("/v1/account", headers=bearer(signed_in["sessionToken"]))

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"accountId", "dailyScanLimit", "createdAt"}
    assert body["accountId"] == signed_in["accountId"]
    assert body["dailyScanLimit"] == 60
    assert body["createdAt"] == datetime.now(timezone.utc).date().isoformat()


@pytest.mark.parametrize(
    "headers",
    [
        pytest.param({}, id="no-header"),
        pytest.param({"Authorization": "Bearer"}, id="empty"),
        pytest.param({"Authorization": "Basic dXNlcjpwYXNz"}, id="basic"),
        pytest.param({"Authorization": "Bearer short"}, id="malformed"),
        pytest.param({"Authorization": "Bearer " + "x" * 43}, id="unknown"),
    ],
)
def test_signed_out_is_401(world: World, headers: dict[str, str]) -> None:
    world.session()
    for method, path in (("GET", "/v1/account"), ("POST", "/v1/account/signout"), ("DELETE", "/v1/account")):
        response = world.client.request(method, path, headers=headers)
        assert response.status_code == 401, (method, path)
        assert response.json() == {"detail": MSG_SIGNED_OUT}
    assert len(world.supabase.accounts) == 1
    assert world.apple.calls["revoke"] == 0


def test_session_unused_for_a_year_is_signed_out(world: World) -> None:
    token = world.session()
    world.supabase.sessions[sha256_hex(token)]["last_used_at"] = (
        datetime.now(timezone.utc) - timedelta(days=366)
    ).isoformat()

    response = world.client.get("/v1/account", headers=bearer(token))
    assert response.status_code == 401
    assert world.supabase.sessions == {}  # the dead session is gone
    assert len(world.supabase.accounts) == 1  # the account itself stays


def test_using_a_session_keeps_it_alive(world: World) -> None:
    token = world.session()
    two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
    session = world.supabase.sessions[sha256_hex(token)]
    session["last_used_at"] = two_days_ago

    assert world.client.get("/v1/account", headers=bearer(token)).status_code == 200
    assert session["last_used_at"] > two_days_ago
    [account] = world.supabase.accounts.values()
    assert account["last_seen_at"] == session["last_used_at"]

    # Used again the same day: no write.
    patches = world.supabase.count("PATCH", "account_sessions")
    assert world.client.get("/v1/account", headers=bearer(token)).status_code == 200
    assert world.supabase.count("PATCH", "account_sessions") == patches


def test_sign_in_clears_sessions_unused_for_a_year(world: World) -> None:
    old = world.session()
    world.supabase.sessions[sha256_hex(old)]["last_used_at"] = (
        datetime.now(timezone.utc) - timedelta(days=400)
    ).isoformat()
    world.session()
    assert sha256_hex(old) not in world.supabase.sessions
    assert len(world.supabase.sessions) == 1


def test_sign_out_ends_only_that_session(world: World) -> None:
    first = world.session()
    second = world.session()

    response = world.client.post("/v1/account/signout", headers=bearer(first))
    assert response.status_code == 204
    assert response.content == b""
    assert world.client.get("/v1/account", headers=bearer(first)).status_code == 401
    assert world.client.get("/v1/account", headers=bearer(second)).status_code == 200
    assert len(world.supabase.accounts) == 1
    assert world.apple.calls["revoke"] == 0


def test_delete_revokes_at_apple_and_deletes_everything(world: World) -> None:
    first = world.session()
    second = world.session()
    newest_refresh = list(world.apple.refresh_tokens)[-1]

    response = world.client.delete("/v1/account", headers=bearer(first))
    assert response.status_code == 204, response.text
    assert world.apple.revoked == [newest_refresh]
    assert world.supabase.accounts == {}
    assert world.supabase.sessions == {}
    assert world.client.get("/v1/account", headers=bearer(second)).status_code == 401


@pytest.mark.parametrize(
    "break_apple",
    [
        pytest.param(lambda a: a.down.add("revoke"), id="unreachable"),
        pytest.param(lambda a: a.status.update(revoke=503), id="server-error"),
        pytest.param(lambda a: (a.status.update(revoke=400), a.error.update(revoke="invalid_client")), id="invalid-client"),
    ],
)
def test_delete_with_apple_down_keeps_the_account(world: World, break_apple: Callable[[FakeApple], Any]) -> None:
    token = world.session()
    break_apple(world.apple)

    response = world.client.delete("/v1/account", headers=bearer(token))
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_DELETE_APPLE_DOWN}
    assert len(world.supabase.accounts) == 1
    assert len(world.supabase.sessions) == 1
    assert world.client.get("/v1/account", headers=bearer(token)).status_code == 200


def test_delete_when_apple_already_forgot_the_token(world: World) -> None:
    token = world.session()
    world.apple.status["revoke"] = 400
    world.apple.error["revoke"] = "invalid_grant"
    assert world.client.delete("/v1/account", headers=bearer(token)).status_code == 204
    assert world.supabase.accounts == {}


def test_delete_with_store_down_is_502(world: World) -> None:
    token = world.session()
    world.supabase.down = True
    response = world.client.delete("/v1/account", headers=bearer(token))
    assert response.status_code == 502
    assert response.json() == {"detail": MSG_ACCOUNT_STORE}


# ---------------------------------------------------------------------- nothing secret leaks


def test_secrets_never_reach_logs_or_responses(world: World, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    caplog.set_level(logging.DEBUG, logger="auditioner")
    caplog.set_level(logging.DEBUG, logger="httpx")

    identity_token = world.apple.identity_token()
    code = world.apple.issue_code()
    responses: list[httpx.Response] = []
    responses.append(world.client.post(
        "/v1/account/apple", json={"identityToken": identity_token, "authorizationCode": code, "nonce": RAW_NONCE}
    ))
    token = responses[0].json()["sessionToken"]
    responses.append(world.client.get("/v1/account", headers=bearer(token)))
    responses.append(post_omr(world.client, headers={**DEVICE, **bearer(token)}))
    # Failure paths log too: bad nonce, Apple down for the exchange, store down.
    responses.append(world.sign_in(nonce="wrong"))
    world.apple.down.add("token")
    responses.append(world.sign_in())
    world.apple.down.clear()
    world.apple.down.add("revoke")
    responses.append(world.client.delete("/v1/account", headers=bearer(token)))
    world.apple.down.clear()
    second = world.session()
    responses.append(world.client.post("/v1/account/signout", headers=bearer(token)))
    responses.append(world.client.delete("/v1/account", headers=bearer(second)))
    assert responses[-1].status_code == 204

    secrets_seen = [
        identity_token,
        code,
        RAW_NONCE,
        token,
        second,
        APPLE_SUB,
        ACCOUNT_SECRET,
        SERVICE_KEY,
        ec_pem().splitlines()[1],
        *world.apple.refresh_tokens,
        *world.apple.client_secrets,
    ]
    logged = caplog.text + "\n".join(r.getMessage() for r in caplog.records)
    for value in secrets_seen:
        assert value not in logged
    for value in [*world.apple.refresh_tokens, APPLE_SUB, ACCOUNT_SECRET, *world.apple.client_secrets]:
        for response in responses:
            assert value not in response.text
    for shown in (repr(world.service), repr(world.service.apple), repr(world.service.store), repr(world.settings)):
        assert ACCOUNT_SECRET not in shown and SERVICE_KEY not in shown and "PRIVATE KEY" not in shown


# ---------------------------------------------------------------------- the scan limit


def test_signed_in_scans_use_the_account_limit(world_factory: Callable[..., World]) -> None:
    world = world_factory(daily_scan_limit=1, signed_in_daily_scan_limit=2)
    signed_in = world.sign_in().json()
    assert signed_in["dailyScanLimit"] == 2
    headers = {**DEVICE, **bearer(signed_in["sessionToken"])}

    assert post_omr(world.client, headers=headers).status_code == 200
    assert post_omr(world.client, headers=headers).status_code == 200
    third = post_omr(world.client, headers=headers)
    assert third.status_code == 429
    assert world.app.state.account_limiter.remaining("account:" + signed_in["accountId"]) == 0

    # The device's own allowance was never touched.
    assert world.app.state.limiter.remaining(DEVICE["X-Device-Id"]) == 1
    assert post_omr(world.client).status_code == 200
    assert post_omr(world.client).status_code == 429


@pytest.mark.parametrize(
    "authorization",
    [
        pytest.param("Bearer " + "x" * 43, id="unknown-token"),
        pytest.param("Bearer short", id="malformed-token"),
        pytest.param("Basic dXNlcjpwYXNz", id="not-bearer"),
    ],
)
def test_bad_token_scans_use_the_device_limit(world_factory: Callable[..., World], authorization: str) -> None:
    world = world_factory(daily_scan_limit=1, signed_in_daily_scan_limit=5)
    world.session()
    headers = {**DEVICE, "Authorization": authorization}

    assert post_omr(world.client, headers=headers).status_code == 200
    assert post_omr(world.client, headers=headers).status_code == 429


def test_scan_never_fails_because_the_account_store_is_down(world_factory: Callable[..., World]) -> None:
    world = world_factory(daily_scan_limit=1, signed_in_daily_scan_limit=5)
    token = world.session()
    world.supabase.down = True

    response = post_omr(world.client, headers={**DEVICE, **bearer(token)})
    assert response.status_code == 200, response.text
    assert world.app.state.limiter.remaining(DEVICE["X-Device-Id"]) == 0  # counted per device


def test_scan_never_fails_when_accounts_are_off(world_factory: Callable[..., World]) -> None:
    world = world_factory(account_secret="", daily_scan_limit=1)
    response = post_omr(world.client, headers={**DEVICE, **bearer("x" * 43)})
    assert response.status_code == 200
    assert post_omr(world.client).status_code == 429


def test_scan_look_ups_are_cached_for_five_minutes(world_factory: Callable[..., World]) -> None:
    world = world_factory(daily_scan_limit=1, signed_in_daily_scan_limit=10)
    token = world.session()
    headers = {**DEVICE, **bearer(token)}
    looked_up = world.supabase.count("GET", "account_sessions")

    assert post_omr(world.client, headers=headers).status_code == 200
    assert post_omr(world.client, headers=headers).status_code == 200
    assert world.supabase.count("GET", "account_sessions") == looked_up + 1

    world.clock.now += 301
    assert post_omr(world.client, headers=headers).status_code == 200
    assert world.supabase.count("GET", "account_sessions") == looked_up + 2

    # Signing out on this instance forgets the cached answer at once.
    assert world.client.post("/v1/account/signout", headers=bearer(token)).status_code == 204
    assert post_omr(world.client, headers=headers).status_code == 200  # device allowance: 1
    assert post_omr(world.client, headers=headers).status_code == 429
