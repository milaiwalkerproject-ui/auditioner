"""HTTP routes for the optional Sign in with Apple accounts (PLAN B2) and the
signed-in scan limit. The logic is in app/accounts.py; main.py calls
``install_accounts(app, settings)`` once and asks ``scan_allowance`` what a scan
counts against.

    POST   /v1/account/apple    {"identityToken", "authorizationCode", "nonce"}
                                → {"accountId", "sessionToken", "dailyScanLimit"}
    GET    /v1/account          Bearer → {"accountId", "dailyScanLimit", "createdAt": "YYYY-MM-DD"}
    POST   /v1/account/signout  Bearer → 204 (this session only)
    DELETE /v1/account          Bearer → 204 (Apple token revoked, account and sessions deleted)

Errors are {"detail": "<plain words>"} like everywhere else: 400 Apple couldn't
confirm the sign-in, 401 signed out, 429 too many sign-ins from one network in an
hour (HOURLY_SIGN_IN_LIMIT, app/limits.py), 502 Apple or the account store didn't
answer, 503 accounts aren't set up on this server.

The scan limit (``scan_allowance``): every scan counts against the device
(X-Device-Id) — up to DAILY_SCAN_LIMIT signed out, up to SIGNED_IN_DAILY_SCAN_LIMIT
with a valid Bearer session — and a signed-in scan also counts against the account
(SIGNED_IN_DAILY_SCAN_LIMIT). One device counter is shared by both, so signing out
and in again, or in with another Apple ID, never adds up to more than the signed-in
limit on one device.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, FastAPI, Request
from fastapi.exceptions import HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from .accounts import (
    MAX_AUTH_CODE_CHARS,
    MAX_IDENTITY_TOKEN_CHARS,
    MAX_NONCE_CHARS,
    MSG_ACCOUNT_STORE,
    MSG_ACCOUNTS_OFF,
    MSG_APPLE_UNREACHABLE,
    MSG_BAD_APPLE_TOKEN,
    MSG_DELETE_APPLE_DOWN,
    MSG_SIGNED_OUT,
    AccountService,
    AccountsOff,
    AccountStoreError,
    AppleTokenInvalid,
    AppleUnavailable,
    SignedOut,
    bearer_token,
)
from .config import Settings
from .limits import HOUR_SECONDS, MSG_TOO_MANY_REQUESTS, DailyLimiter, request_network

log = logging.getLogger("auditioner.accounts")

router = APIRouter()

NO_STORE = {"Cache-Control": "no-store"}


# Apple's tokens and codes, and the app's raw nonce, are printable ASCII without spaces.
PRINTABLE_ASCII = r"^[\x21-\x7e]+$"


class AppleSignInRequest(BaseModel):
    identityToken: str = Field(min_length=1, max_length=MAX_IDENTITY_TOKEN_CHARS, pattern=PRINTABLE_ASCII)
    authorizationCode: str = Field(min_length=1, max_length=MAX_AUTH_CODE_CHARS, pattern=PRINTABLE_ASCII)
    nonce: str = Field(min_length=1, max_length=MAX_NONCE_CHARS, pattern=PRINTABLE_ASCII)


def install_accounts(app: FastAPI, settings: Settings) -> None:
    """Put the account service and the signed-in scan limiter on app.state and add
    the routes. Says once in the log which settings are missing (names only) when
    some, but not all, of the account settings are there."""
    service = AccountService.from_settings(settings)
    app.state.accounts = service
    app.state.account_limiter = DailyLimiter(settings.signed_in_daily_scan_limit)
    # Sign-in attempts per network address per sliding hour (keys are never logged).
    app.state.sign_in_network_limiter = DailyLimiter(settings.hourly_sign_in_limit, window_seconds=HOUR_SECONDS)
    started = any(
        (value or "").strip()
        for value in (settings.apple_team_id, settings.apple_key_id, settings.apple_private_key, settings.account_secret)
    )
    if started and not service.configured:
        log.warning("accounts are off until these settings are fixed: %s", ", ".join(service.problems))
    app.include_router(router)


def _service(request: Request) -> AccountService:
    service = getattr(request.app.state, "accounts", None)
    if not isinstance(service, AccountService):
        raise HTTPException(503, MSG_ACCOUNTS_OFF)
    return service


def _signed_out() -> HTTPException:
    return HTTPException(401, MSG_SIGNED_OUT, headers={"WWW-Authenticate": "Bearer"})


def _session_token(request: Request) -> str | None:
    return bearer_token(request.headers.get("authorization"))


@router.post("/v1/account/apple")
async def sign_in_with_apple(body: AppleSignInRequest, request: Request) -> JSONResponse:
    service = _service(request)
    if not service.configured:
        raise HTTPException(503, MSG_ACCOUNTS_OFF)
    # Every attempt that will reach Apple counts, good token or bad: the point is to
    # bound what one network can make this server (and Apple) do in an hour.
    network_limiter = getattr(request.app.state, "sign_in_network_limiter", None)
    if isinstance(network_limiter, DailyLimiter) and not network_limiter.allow(request_network(request)):
        raise HTTPException(429, MSG_TOO_MANY_REQUESTS)
    try:
        result = await service.sign_in(body.identityToken, body.authorizationCode, body.nonce)
    except AccountsOff:
        raise HTTPException(503, MSG_ACCOUNTS_OFF) from None
    except AppleTokenInvalid:
        raise HTTPException(400, MSG_BAD_APPLE_TOKEN) from None
    except AppleUnavailable:
        raise HTTPException(502, MSG_APPLE_UNREACHABLE) from None
    except AccountStoreError:
        raise HTTPException(502, MSG_ACCOUNT_STORE) from None
    return JSONResponse(content=result, headers=NO_STORE)


@router.get("/v1/account")
async def get_account(request: Request) -> JSONResponse:
    service = _service(request)
    try:
        result: dict[str, Any] = await service.account(_session_token(request))
    except AccountsOff:
        raise HTTPException(503, MSG_ACCOUNTS_OFF) from None
    except SignedOut:
        raise _signed_out() from None
    except AccountStoreError:
        raise HTTPException(502, MSG_ACCOUNT_STORE) from None
    return JSONResponse(content=result, headers=NO_STORE)


@router.post("/v1/account/signout", status_code=204)
async def sign_out(request: Request) -> Response:
    service = _service(request)
    try:
        await service.sign_out(_session_token(request))
    except AccountsOff:
        raise HTTPException(503, MSG_ACCOUNTS_OFF) from None
    except SignedOut:
        raise _signed_out() from None
    except AccountStoreError:
        raise HTTPException(502, MSG_ACCOUNT_STORE) from None
    return Response(status_code=204)


@router.delete("/v1/account", status_code=204)
async def delete_account(request: Request) -> Response:
    service = _service(request)
    try:
        await service.delete(_session_token(request))
    except AccountsOff:
        raise HTTPException(503, MSG_ACCOUNTS_OFF) from None
    except SignedOut:
        raise _signed_out() from None
    except AppleUnavailable:
        raise HTTPException(502, MSG_DELETE_APPLE_DOWN) from None
    except AccountStoreError:
        raise HTTPException(502, MSG_ACCOUNT_STORE) from None
    return Response(status_code=204)


class ScanAllowance:
    """What one scan counts against, worked out once per request by `scan_allowance`.

    The device counter (`device_limiter`, keyed by X-Device-Id) is charged for every
    scan, against `device_limit`: DAILY_SCAN_LIMIT signed out, the signed-in limit
    when a valid session came with the scan. A signed-in scan is also charged to the
    account (`account_limiter`, keyed "account:<id>"). `allow` charges all of them or
    none; `refund` gives all of them back (the server was busy and did no work)."""

    def __init__(
        self,
        device_limiter: DailyLimiter,
        device_id: str,
        device_limit: int,
        account_limiter: DailyLimiter | None = None,
        account_key: str | None = None,
    ) -> None:
        self.device_limiter = device_limiter
        self.device_id = device_id
        self.device_limit = int(device_limit)
        self.account_limiter = account_limiter
        self.account_key = account_key

    @property
    def signed_in(self) -> bool:
        return self.account_limiter is not None and self.account_key is not None

    def allow(self) -> bool:
        if self.account_limiter is not None and self.account_key is not None:
            if not self.account_limiter.allow(self.account_key):
                return False
            if not self.device_limiter.allow(self.device_id, limit=self.device_limit):
                self.account_limiter.refund(self.account_key)  # charged nothing in the end
                return False
            return True
        return self.device_limiter.allow(self.device_id, limit=self.device_limit)

    def refund(self) -> None:
        self.device_limiter.refund(self.device_id)
        if self.account_limiter is not None and self.account_key is not None:
            self.account_limiter.refund(self.account_key)


async def scan_allowance(request: Request, device_id: str) -> ScanAllowance:
    """The counters a scan counts against (see `ScanAllowance`). Never raises.

    A valid Bearer session → device (up to the signed-in limit) and account. No
    token, a bad or expired one, accounts off, the database down or slow (the look-up
    is bounded as a whole, `AccountService.scan_account`) → the device alone, up to
    DAILY_SCAN_LIMIT. Signing in never lowers the device's cap: it is the larger of the
    two limits, should SIGNED_IN_DAILY_SCAN_LIMIT ever be set below DAILY_SCAN_LIMIT."""
    device_limiter: DailyLimiter = request.app.state.limiter
    signed_out = ScanAllowance(device_limiter, device_id, device_limiter.limit)
    token = _session_token(request)
    if not token:
        return signed_out
    service = getattr(request.app.state, "accounts", None)
    account_limiter = getattr(request.app.state, "account_limiter", None)
    if not isinstance(service, AccountService) or not isinstance(account_limiter, DailyLimiter):
        return signed_out
    try:
        account_id = await service.scan_account(token)
    except Exception:  # scan_account never raises; this is belt and braces
        account_id = None
    if not account_id:
        return signed_out
    return ScanAllowance(
        device_limiter,
        device_id,
        max(device_limiter.limit, account_limiter.limit),
        account_limiter,
        "account:" + account_id,
    )
