"""Shared fixtures: fake clock/sleep, a fake Anthropic client, tiny PDF/DOCX builders,
a fixture registry and a fixture catalogue. No test touches the network."""

from __future__ import annotations

import io
import json
import zipfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import pytest

from crawler.config import Settings
from crawler.mapping import Catalogue
from crawler.registry import Registry, load_registry

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FIXTURE_REGISTRY = FIXTURES / "registry.json"
FIXTURE_CATALOG = FIXTURES / "catalog"


# ------------------------------------------------------------------ clock


class FakeClock:
    def __init__(self, start: float = 1000.0) -> None:
        self.now = start
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock()


# ------------------------------------------------------------------ registry / catalogue


@pytest.fixture
def registry() -> Registry:
    return load_registry(FIXTURE_REGISTRY, strict=True)


@pytest.fixture
def catalogue() -> Catalogue:
    return Catalogue.load(FIXTURE_CATALOG)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(registry_path=FIXTURE_REGISTRY, catalog_dir=FIXTURE_CATALOG, out_dir=tmp_path / "out")


# ------------------------------------------------------------------ documents


def _pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def make_pdf(lines: list[str], *, pages: int = 1) -> bytes:
    """A minimal valid PDF (Helvetica, one text block per page) that pypdf can read.
    ASCII only — WinAnsi has no 'ř'."""
    objects: list[bytes] = []

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)

    catalog_id = add(b"")  # placeholder, filled later
    pages_id = add(b"")
    font_id = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    page_ids: list[int] = []
    per_page = max(1, (len(lines) + pages - 1) // pages)
    for page in range(pages):
        chunk = lines[page * per_page:(page + 1) * per_page]
        ops = ["BT", "/F1 12 Tf", "14 TL", "72 720 Td"]
        for index, line in enumerate(chunk):
            if index:
                ops.append("T*")
            ops.append(f"({_pdf_escape(line)}) Tj")
        ops.append("ET")
        stream = ("\n".join(ops)).encode("latin-1")
        content_id = add(b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
        page_id = add(
            b"<< /Type /Page /Parent " + str(pages_id).encode() + b" 0 R /MediaBox [0 0 612 792] /Contents "
            + str(content_id).encode() + b" 0 R /Resources << /Font << /F1 " + str(font_id).encode() + b" 0 R >> >> >>"
        )
        page_ids.append(page_id)
    objects[catalog_id - 1] = b"<< /Type /Catalog /Pages " + str(pages_id).encode() + b" 0 R >>"
    kids = b" ".join(str(p).encode() + b" 0 R" for p in page_ids)
    objects[pages_id - 1] = b"<< /Type /Pages /Kids [" + kids + b"] /Count " + str(len(page_ids)).encode() + b" >>"

    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(out.tell())
        out.write(str(number).encode() + b" 0 obj\n" + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 " + str(len(objects) + 1).encode() + b"\n0000000000 65535 f \n")
    for offset in offsets:
        out.write(f"{offset:010d} 00000 n \n".encode())
    out.write(b"trailer\n<< /Size " + str(len(objects) + 1).encode() + b" /Root " + str(catalog_id).encode() + b" 0 R >>\n")
    out.write(b"startxref\n" + str(xref).encode() + b"\n%%EOF\n")
    return out.getvalue()


def make_docx(paragraphs: list[str]) -> bytes:
    body = "".join(
        f"<w:p><w:r><w:t xml:space=\"preserve\">{p.replace('&', '&amp;').replace('<', '&lt;')}</w:t></w:r></w:p>"
        for p in paragraphs
    )
    document = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}</w:body></w:document>"
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        archive.writestr("word/document.xml", document)
    return buffer.getvalue()


# ------------------------------------------------------------------ fake Anthropic client


@dataclass
class FakeUsage:
    input_tokens: int = 1200
    output_tokens: int = 300
    cache_read_input_tokens: int = 0
    cache_creation_input_tokens: int = 0


@dataclass
class FakeResponse:
    data: Any = None
    stop_reason: str = "end_turn"
    model: str = "fake-model"
    text: str | None = None
    stop_details: Any = None
    usage: FakeUsage = field(default_factory=FakeUsage)
    _request_id: str = "req_test"

    @property
    def content(self) -> list[Any]:
        if self.stop_reason == "refusal":
            return []
        text = self.text if self.text is not None else json.dumps(self.data)
        return [SimpleNamespace(type="text", text=text)]


Responder = Callable[[dict[str, Any]], Any]


class _Messages:
    def __init__(self, client: FakeAnthropic, path: str) -> None:
        self._client = client
        self._path = path
        self.batches = _Batches(client)

    def create(self, **kwargs: Any) -> Any:
        self._client.calls.append((self._path, kwargs))
        result = self._client.responder(kwargs)
        if isinstance(result, Exception):
            raise result
        if isinstance(result, FakeResponse):
            if result.model == "fake-model":
                result.model = kwargs.get("model", "fake-model")
            return result
        return FakeResponse(data=result, model=kwargs.get("model", "fake-model"))


class _Batches:
    def __init__(self, client: FakeAnthropic) -> None:
        self._client = client
        self.created: list[list[dict[str, Any]]] = []
        self.status = "ended"

    def create(self, *, requests: list[dict[str, Any]]) -> Any:
        self.created.append(requests)
        return SimpleNamespace(id=f"msgbatch_{len(self.created)}", processing_status="in_progress")

    def retrieve(self, batch_id: str) -> Any:
        return SimpleNamespace(id=batch_id, processing_status=self.status)

    def results(self, batch_id: str) -> Any:
        requests = self.created[-1] if self.created else []
        for request in requests:
            response = _Messages(self._client, "batch").create(**request["params"])
            yield SimpleNamespace(custom_id=request["custom_id"], result=SimpleNamespace(type="succeeded", message=response))


class FakeAnthropic:
    """Mimics the parts of anthropic.Anthropic the crawler uses: `messages.create`,
    `beta.messages.create`, `messages.batches.{create,retrieve,results}`."""

    def __init__(self, responder: Responder | None = None) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.responder: Responder = responder or (lambda kwargs: {})
        self.messages = _Messages(self, "messages")
        self.beta = SimpleNamespace(messages=_Messages(self, "beta.messages"))

    def calls_for(self, model_fragment: str) -> list[dict[str, Any]]:
        return [kwargs for _, kwargs in self.calls if model_fragment in kwargs.get("model", "")]


def user_text(kwargs: dict[str, Any]) -> str:
    """The text block of the single user message in a request."""
    for block in kwargs["messages"][0]["content"]:
        if block.get("type") == "text":
            return block["text"]
    return ""


def numbered_lines(kwargs: dict[str, Any]) -> dict[str, str]:
    """Parse 'L0001: text' lines back out of a request's user text."""
    out: dict[str, str] = {}
    for line in user_text(kwargs).splitlines():
        if line[:1] == "L" and line[1:5].isdigit() and line[5:7] == ": ":
            out[line[:5]] = line[7:]
    return out


def find_lines(lines: dict[str, str], *needles: str) -> list[str]:
    return [line_id for line_id, text in lines.items() if any(n.lower() in text.lower() for n in needles)]


@pytest.fixture
def fake_anthropic() -> FakeAnthropic:
    return FakeAnthropic()


# ------------------------------------------------------------------ HTTP


class RouteTable:
    """A tiny in-test web: url → handler(request) → Response, with a request log."""

    def __init__(self) -> None:
        self.routes: dict[str, Callable[[httpx.Request], httpx.Response]] = {}
        self.requests: list[httpx.Request] = []

    def add(self, url: str, handler: Callable[[httpx.Request], httpx.Response] | httpx.Response) -> None:
        if isinstance(handler, httpx.Response):
            response = handler
            handler = lambda request, response=response: httpx.Response(  # noqa: E731
                response.status_code, headers=response.headers, content=response.content
            )
        self.routes[url] = handler

    def html(self, url: str, body: str, **headers: str) -> None:
        self.add(url, httpx.Response(200, headers={"content-type": "text/html; charset=utf-8", **headers}, content=body.encode("utf-8")))

    def pdf(self, url: str, data: bytes, **headers: str) -> None:
        self.add(url, httpx.Response(200, headers={"content-type": "application/pdf", **headers}, content=data))

    def text(self, url: str, body: str, status: int = 200, **headers: str) -> None:
        self.add(url, httpx.Response(status, headers={"content-type": "text/plain", **headers}, content=body.encode("utf-8")))

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        key = str(request.url)
        if key in self.routes:
            return self.routes[key](request)
        return httpx.Response(404, headers={"content-type": "text/plain"}, content=b"not found")

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)

    def requested(self, url: str) -> list[httpx.Request]:
        return [r for r in self.requests if str(r.url) == url]


@pytest.fixture
def web() -> RouteTable:
    return RouteTable()
