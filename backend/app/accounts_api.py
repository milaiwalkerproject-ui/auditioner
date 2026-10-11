"""HTTP routes for the optional Sign in with Apple accounts (PLAN B2) and the
signed-in scan limit. The logic is in app/accounts.py; main.py calls
``install_accounts(app, settings)`` once and asks ``scan_limiter`` which daily
limit a scan counts against.

    POST   /v1/account/apple    {"identityToken", "authorizationCode", "nonce"}
                                → {"accountId", "sessionToken", "dailyScanLimit"}
    GET    /v1/account          Bearer → {"accountId", "dailyScanLimit", "createdAt": "YYYY-MM-DD"}
    POST   /v1/account/signout  Bearer → 204 (this session only)
    DELETE /v1/account          Bearer → 204 (Apple token revoked, account and sessions deleted)

Errors are {"detail": "<plain words>"} like everywhere else: 400 Apple couldn't
confirm the sign-in, 401 signed out, 502 Apple or the account store didn't answer,
503 accounts aren't set up on this server.
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
from .limits import DailyLimiter

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


async def scan_limiter(request: Request, device_id: str) -> tuple[DailyLimiter, str]:
    """Which daily limit a scan counts against, and under which key.

    A valid Bearer session → the per-account limiter (SIGNED_IN_DAILY_SCAN_LIMIT),
    keyed by account id. No token, a bad or expired one, accounts off or the
    database down → the per-device limiter (DAILY_SCAN_LIMIT). Never raises."""
    device_limiter: DailyLimiter = request.app.state.limiter
    token = _session_token(request)
    if not token:
        return device_limiter, device_id
    service = getattr(request.app.state, "accounts", None)
    account_limiter = getattr(request.app.state, "account_limiter", None)
    if not isinstance(service, AccountService) or not isinstance(account_limiter, DailyLimiter):
        return device_limiter, device_id
    try:
        account_id = await service.scan_account(token)
    except Exception:  # scan_account never raises; this is belt and braces
        account_id = None
    if not account_id:
        return device_limiter, device_id
    return account_limiter, "account:" + account_id
