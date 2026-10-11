"""Turning fetched bytes into numbered source lines.

Every line gets a stable id ("L0001"). Claude cites those ids for each extracted
item and the verifier (verify.py) checks the citation against the same lines — the
model never gets to assert a fact the text does not carry.

PDF text comes from pypdf. .docx is read directly (it is a zip with XML inside).
.doc needs LibreOffice (`soffice --headless`), used unmodified as a separate process
when present; otherwise the document is skipped with a note.
"""

from __future__ import annotations

import hashlib
import io
import logging
import re
import shutil
import subprocess
import tempfile
import zipfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree

from pypdf import PdfReader

log = logging.getLogger("auditioner.crawler.documents")

WORD_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
SOFFICE_TIMEOUT_SECONDS = 180
DOCUMENT_CONTENT_TYPES = {
    "application/pdf": "pdf",
    "application/x-pdf": "pdf",
    "application/msword": "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
}


@dataclass(frozen=True)
class SourceLine:
    id: str
    text: str
    page: int | None = None


@dataclass
class ExtractedText:
    kind: str  # pdf | docx | doc | html | text
    lines: list[SourceLine] = field(default_factory=list)
    pages: int = 0
    notes: list[str] = field(default_factory=list)
    skipped: bool = False

    @property
    def by_id(self) -> dict[str, SourceLine]:
        return {line.id: line for line in self.lines}

    @property
    def text(self) -> str:
        return "\n".join(line.text for line in self.lines)

    def text_hash(self) -> str:
        return hashlib.sha256(self.text.encode("utf-8")).hexdigest()

    def numbered(self, max_lines: int | None = None) -> str:
        chosen = self.lines if max_lines is None else self.lines[:max_lines]
        out = [f"{line.id}: {line.text}" for line in chosen]
        if max_lines is not None and len(self.lines) > max_lines:
            out.append(f"[... {len(self.lines) - max_lines} more lines not shown]")
        return "\n".join(out)

    @property
    def has_text(self) -> bool:
        return any(line.text.strip() for line in self.lines)


def _line_id(index: int) -> str:
    return f"L{index:04d}"


def lines_from_text(text: str, *, kind: str = "text", page: int | None = None, start: int = 1) -> list[SourceLine]:
    lines: list[SourceLine] = []
    index = start
    for raw in text.splitlines():
        cleaned = re.sub(r"[ \t ]+", " ", raw).strip()
        if not cleaned:
            continue
        lines.append(SourceLine(id=_line_id(index), text=cleaned, page=page))
        index += 1
    return lines


def text_document(text: str, *, kind: str = "html") -> ExtractedText:
    return ExtractedText(kind=kind, lines=lines_from_text(text), pages=1)


def append_lines(doc: ExtractedText, extra: Iterable[str], *, page: int | None = None) -> None:
    start = len(doc.lines) + 1
    text = "\n".join(extra)
    doc.lines.extend(lines_from_text(text, page=page, start=start))


def pdf_text(data: bytes) -> ExtractedText:
    doc = ExtractedText(kind="pdf")
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            try:
                reader.decrypt("")
            except Exception:  # pragma: no cover - depends on the file
                doc.notes.append("PDF is encrypted; no text read")
                return doc
        pages = list(reader.pages)
    except Exception as exc:  # pypdf raises many specific errors; none should stop the run
        doc.notes.append(f"PDF could not be read: {exc.__class__.__name__}")
        return doc
    doc.pages = len(pages)
    index = 1
    for number, page in enumerate(pages, start=1):
        try:
            text = page.extract_text() or ""
        except Exception as exc:
            doc.notes.append(f"page {number}: text extraction failed ({exc.__class__.__name__})")
            continue
        page_lines = lines_from_text(text, page=number, start=index)
        index += len(page_lines)
        doc.lines.extend(page_lines)
    if not doc.has_text:
        doc.notes.append("PDF has no text layer (a scan?) — items cannot cite lines and will need review")
    return doc


def docx_text(data: bytes) -> ExtractedText:
    doc = ExtractedText(kind="docx")
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            xml = archive.read("word/document.xml")
    except (zipfile.BadZipFile, KeyError) as exc:
        doc.notes.append(f"docx could not be opened: {exc.__class__.__name__}")
        return doc
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError:
        doc.notes.append("docx XML is malformed")
        return doc
    paragraphs: list[str] = []
    for paragraph in root.iter(f"{WORD_NS}p"):
        parts: list[str] = []
        for node in paragraph.iter():
            if node.tag == f"{WORD_NS}t" and node.text:
                parts.append(node.text)
            elif node.tag == f"{WORD_NS}tab":
                parts.append(" ")
            elif node.tag == f"{WORD_NS}br":
                parts.append("\n")
        text = "".join(parts)
        if text.strip():
            paragraphs.append(text)
    doc.lines = lines_from_text("\n".join(paragraphs), page=1)
    doc.pages = 1
    if not doc.has_text:
        doc.notes.append("docx carried no text")
    return doc


def doc_text(data: bytes, *, which: Callable[[str], str | None] = shutil.which,
             run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> ExtractedText:
    """Legacy .doc: convert to PDF with LibreOffice when it is installed, else skip."""
    doc = ExtractedText(kind="doc")
    soffice = which("soffice") or which("libreoffice")
    if not soffice:
        doc.skipped = True
        doc.notes.append("legacy .doc skipped: LibreOffice (soffice) is not installed on this machine")
        return doc
    with tempfile.TemporaryDirectory(prefix="auditioner-doc-") as tmp:
        source = Path(tmp) / "input.doc"
        source.write_bytes(data)
        try:
            run(
                [soffice, "--headless", "--norestore", "--convert-to", "pdf", "--outdir", tmp, str(source)],
                check=False,
                capture_output=True,
                timeout=SOFFICE_TIMEOUT_SECONDS,
                env={"HOME": tmp, "PATH": "/usr/bin:/bin:/usr/local/bin"},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            doc.skipped = True
            doc.notes.append(f"legacy .doc skipped: LibreOffice failed ({exc.__class__.__name__})")
            return doc
        produced = Path(tmp) / "input.pdf"
        if not produced.exists():
            doc.skipped = True
            doc.notes.append("legacy .doc skipped: LibreOffice produced no PDF")
            return doc
        converted = pdf_text(produced.read_bytes())
    converted.kind = "doc"
    converted.notes.insert(0, "converted from .doc with LibreOffice")
    return converted


def document_kind(url: str, content_type: str | None) -> str | None:
    path = url.lower().split("?", 1)[0]
    for suffix in (".pdf", ".docx", ".doc"):
        if path.endswith(suffix):
            return suffix[1:]
    if content_type:
        return DOCUMENT_CONTENT_TYPES.get(content_type.split(";")[0].strip().lower())
    return None


def extract_document(data: bytes, *, url: str, content_type: str | None = None) -> ExtractedText:
    kind = document_kind(url, content_type)
    if kind is None and data[:5] == b"%PDF-":
        kind = "pdf"
    if kind is None and data[:2] == b"PK":
        kind = "docx"
    if kind == "pdf":
        return pdf_text(data)
    if kind == "docx":
        return docx_text(data)
    if kind == "doc":
        return doc_text(data)
    doc = ExtractedText(kind="unknown", skipped=True)
    doc.notes.append(f"not a document type we read ({content_type or 'unknown type'})")
    return doc
