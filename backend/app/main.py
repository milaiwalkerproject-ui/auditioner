"""Auditioner API (FastAPI). Endpoints match ios/Auditioner/Core/Networking/APIClient.swift.

    GET  /healthz                   → {"status": "ok", "engine": "homr", "version": "…"}
    POST /v1/omr                    multipart image + instrument + transposition + meter? + hints
                                    → {"musicxml", "warnings", "engine", "measures"}
    POST /v1/identify               {"ocrText", "instrument"} → {"candidates": [{excerptId, score}]}
    GET  /v1/catalog/{instrument}   the catalogue file, with an ETag

Errors are always JSON {"detail": "<plain words for a musician>"} — the app decodes the
error body as a flat {string: string} dictionary, so nothing else may appear in it.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
from starlette.datastructures import Headers
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import __version__
from .catalog import Catalog
from .config import Settings
from .imaging import ImageTooLarge, NotAnImage, probe
from .instruments import INSTRUMENT_IDS, lookup
from .limits import Busy, ConcurrencyGuard, DailyLimiter, clean_device_id
from .omr import EngineError, EngineTimeout, recognise
from .postprocess import MalformedMusicXML, parse_meter, postprocess

log = logging.getLogger("auditioner.api")

ENGINE = "homr"
TRANSPOSITION_RANGE = (-36, 36)
MAX_HINTS = 200
MAX_HINT_CHARS = 500
MAX_OCR_TEXT_CHARS = 20_000
FORM_OVERHEAD_BYTES = 256 * 1024
# APIClient.swift gives up 120 s after the last byte it received; nothing is sent
# until the scan is done, so queue wait + homr run must stay under this.
REQUEST_BUDGET_SECONDS = 115.0
MIN_RUN_SECONDS = 20.0  # not worth starting homr with less than this left

MSG_NO_DEVICE = "The app didn't say which device this is (X-Device-Id). Update the app and try again."
MSG_TOO_BIG = "This picture is too big to send (over 15 MB). Take a smaller photo or crop it to the staves."
MSG_NOT_IMAGE = "This file isn't a picture we can read. Send a JPEG or PNG photo of the page."
MSG_TOO_MANY_PIXELS = "This picture has far too many pixels for a page. Take a normal photo and try again."
MSG_LIMIT = "Daily scan limit reached. Try again tomorrow."
MSG_BUSY = "Busy — try again in a minute"
MSG_TIMEOUT = "Reading this page took too long. Try a clearer, straighter photo of fewer staves."
MSG_ENGINE = "The notes couldn't be read from this page. Try a clearer, straighter photo."
MSG_SERVER = "Something went wrong on the server. Try again in a minute."
MSG_BAD_HINTS = "The text hints weren't in the expected form (a JSON list of text lines)."
MSG_BAD_METER = "The meter should look like 3/4 or 6/8."
MSG_BAD_TRANSPOSITION = "Transposition must be a whole number of semitones between -36 and 36."


class IdentifyRequest(BaseModel):
    ocrText: str = Field(default="", max_length=MAX_OCR_TEXT_CHARS)
    instrument: str = Field(min_length=1, max_length=40)


class BodyTooLarge(Exception):
    """Raised from the request stream when an upload exceeds the limit."""


class UploadSizeLimit:
    """Pure ASGI middleware: refuses a POST to `path` whose body is over `limit` bytes.

    Honest clients announce Content-Length and are refused before any byte is read.
    Chunked uploads are counted as they arrive and cut off at the limit — while the
    multipart parser is still consuming the stream, i.e. before the whole file has
    been buffered. (Starlette spools file parts to disk after 1 MB, so this bounds
    disk, not RAM; the endpoint's chunked reader bounds RAM.)
    """

    def __init__(self, app: ASGIApp, limit: int, path: str = "/v1/omr") -> None:
        self.app = app
        self.limit = int(limit)
        self.path = path

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("path") != self.path or scope.get("method") != "POST":
            await self.app(scope, receive, send)
            return
        length = Headers(scope=scope).get("content-length", "")
        if length.isdigit() and int(length) > self.limit:
            await JSONResponse(status_code=413, content={"detail": MSG_TOO_BIG})(scope, receive, send)
            return

        received = 0

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.limit:
                    raise BodyTooLarge()
            return message

        await self.app(scope, limited_receive, send)


def _unknown_instrument(value: str) -> str:
    shown = value.strip()[:40] or "(blank)"
    return f"Unknown instrument '{shown}'. Pick your instrument in the app and try again."


def _configure_logging() -> None:
    """Make our one-line-per-scan log visible under uvicorn / Cloud Run (which only
    configure their own loggers) without touching an already configured root."""
    logger = logging.getLogger("auditioner")
    if logger.handlers or logging.getLogger().handlers:
        return
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    _configure_logging()
    app = FastAPI(
        title="Auditioner API",
        version=__version__,
        description="Reads scanned parts with homr and matches them to the excerpt catalogue.",
    )
    app.state.settings = settings
    app.state.limiter = DailyLimiter(settings.daily_scan_limit)
    app.state.guard = ConcurrencyGuard(max_running=1, max_waiting=settings.omr_queue_limit)
    app.state.catalog = Catalog(settings.catalog_dir, include_drafts=settings.include_drafts)
    app.add_middleware(UploadSizeLimit, limit=settings.max_upload_bytes + FORM_OVERHEAD_BYTES)

    # ---------------------------------------------------------------- errors

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        fields = []
        for error in exc.errors():
            loc = [str(p) for p in error.get("loc", []) if p not in ("body", "query", "header")]
            if loc:
                fields.append(".".join(loc))
        what = ", ".join(dict.fromkeys(fields)) or "the request"
        return JSONResponse(
            status_code=422,
            content={"detail": f"Something in the request was missing or malformed: {what}."},
        )

    @app.exception_handler(HTTPException)
    async def http_error(_: Request, exc: HTTPException) -> JSONResponse:
        detail = exc.detail if isinstance(exc.detail, str) else "Something went wrong."
        return JSONResponse(status_code=exc.status_code, content={"detail": detail}, headers=exc.headers)

    @app.exception_handler(BodyTooLarge)
    async def body_too_large(_: Request, __: BodyTooLarge) -> JSONResponse:
        return JSONResponse(status_code=413, content={"detail": MSG_TOO_BIG})

    @app.exception_handler(Exception)
    async def unexpected_error(_: Request, __: Exception) -> JSONResponse:
        # Starlette re-raises after this so the traceback still reaches the server log;
        # the app just needs a JSON body it can show.
        return JSONResponse(status_code=500, content={"detail": MSG_SERVER})

    # ---------------------------------------------------------------- routes

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"status": "ok", "engine": ENGINE, "version": __version__}

    @app.post("/v1/omr")
    async def omr(
        request: Request,
        image: UploadFile = File(...),
        instrument: str = Form(...),
        transposition: int = Form(0),
        meter: str | None = Form(None),
        hints: str = Form("[]"),
    ) -> dict[str, Any]:
        device_id = clean_device_id(request.headers.get("x-device-id"))
        if device_id is None:
            await image.close()
            raise HTTPException(400, MSG_NO_DEVICE)

        info = lookup(instrument)
        if info is None:
            await image.close()
            raise HTTPException(400, _unknown_instrument(instrument))
        if not TRANSPOSITION_RANGE[0] <= transposition <= TRANSPOSITION_RANGE[1]:
            await image.close()
            raise HTTPException(400, MSG_BAD_TRANSPOSITION)
        meter_value = (meter or "").strip() or None
        if meter_value is not None and parse_meter(meter_value) is None:
            await image.close()
            raise HTTPException(400, MSG_BAD_METER)
        hint_lines = _parse_hints(hints)
        if hint_lines is None:
            await image.close()
            raise HTTPException(400, MSG_BAD_HINTS)

        data = await _read_upload(image, settings.max_upload_bytes)
        try:
            probe(data)  # header only: format and declared size, no pixels decoded yet
        except NotAnImage:
            raise HTTPException(415, MSG_NOT_IMAGE) from None
        except ImageTooLarge:
            raise HTTPException(400, MSG_TOO_MANY_PIXELS) from None

        limiter: DailyLimiter = app.state.limiter
        if not limiter.allow(device_id):
            raise HTTPException(429, MSG_LIMIT)

        guard: ConcurrencyGuard = app.state.guard
        started = time.monotonic()
        try:
            async with guard.slot(max_wait=settings.omr_queue_wait_seconds):
                left = REQUEST_BUDGET_SECONDS - (time.monotonic() - started)
                if left < MIN_RUN_SECONDS:
                    raise Busy()
                raw_xml = await recognise(data, settings, timeout=left)
        except Busy:
            limiter.refund(device_id)
            raise HTTPException(503, MSG_BUSY, headers={"Retry-After": "60"}) from None
        except NotAnImage:
            raise HTTPException(415, MSG_NOT_IMAGE) from None
        except ImageTooLarge:
            raise HTTPException(400, MSG_TOO_MANY_PIXELS) from None
        except EngineTimeout:
            raise HTTPException(504, MSG_TIMEOUT) from None
        except EngineError:
            raise HTTPException(500, MSG_ENGINE) from None
        finally:
            del data

        try:
            result = postprocess(
                raw_xml,
                instrument=info,
                transposition=transposition,
                meter=meter_value,
                hints=hint_lines,
            )
        except MalformedMusicXML as exc:
            log.error("engine output could not be parsed: %s", exc)
            raise HTTPException(500, MSG_ENGINE) from None

        log.info(
            "omr ok instrument=%s measures=%s warnings=%d seconds=%.1f",
            info.id, result.measures, len(result.warnings), time.monotonic() - started,
        )
        return {
            "musicxml": result.musicxml,
            "warnings": result.warnings,
            "engine": ENGINE,
            "measures": result.measures,
        }

    @app.post("/v1/identify")
    async def identify(body: IdentifyRequest) -> dict[str, Any]:
        info = lookup(body.instrument)
        if info is None:
            raise HTTPException(400, _unknown_instrument(body.instrument))
        catalog: Catalog = app.state.catalog
        candidates = catalog.identify(body.ocrText, info.id)
        return {"candidates": [{"excerptId": eid, "score": s} for eid, s in candidates]}

    @app.get("/v1/catalog/{instrument}")
    async def catalog_file(instrument: str, request: Request) -> Response:
        catalog: Catalog = app.state.catalog
        info = lookup(instrument)  # only the 22 known ids reach the file system
        loaded = catalog.file(info.id) if info else None
        if loaded is None:
            raise HTTPException(404, f"No catalogue for '{instrument.strip()[:40]}' yet.")
        headers = {"ETag": loaded.etag, "Cache-Control": "public, max-age=300"}
        if_none_match = request.headers.get("if-none-match", "")
        if loaded.etag in [tag.strip() for tag in if_none_match.split(",")]:
            return Response(status_code=304, headers=headers)
        return Response(content=loaded.raw, media_type="application/json", headers=headers)

    @app.get("/v1/instruments")
    async def instruments() -> dict[str, Any]:
        return {"instruments": INSTRUMENT_IDS}

    return app


def _parse_hints(raw: str) -> list[str] | None:
    text = (raw or "").strip()
    if not text:
        return []
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        return None
    return [v[:MAX_HINT_CHARS] for v in value[:MAX_HINTS]]


async def _read_upload(upload: UploadFile, limit: int) -> bytes:
    """Read the file in chunks, refusing anything over `limit` bytes; always closes it."""
    chunks = bytearray()
    try:
        while True:
            chunk = await upload.read(1024 * 1024)
            if not chunk:
                break
            chunks += chunk
            if len(chunks) > limit:
                raise HTTPException(413, MSG_TOO_BIG)
    finally:
        await upload.close()
    return bytes(chunks)


app = create_app()
