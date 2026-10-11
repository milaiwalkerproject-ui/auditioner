from __future__ import annotations

import subprocess

from crawler.documents import (
    ExtractedText,
    append_lines,
    doc_text,
    document_kind,
    extract_document,
    pdf_text,
    text_document,
)

from .conftest import make_docx, make_pdf

LINES = ["Section Cello audition", "Beethoven: Symphony No. 5, mvt. II, mm. 1-106", "Strauss: Don Juan, mm. 1-62"]


def test_pdf_lines_get_stable_ids_and_pages():
    doc = pdf_text(make_pdf(LINES + ["Page two line"], pages=2))
    assert doc.kind == "pdf" and doc.pages == 2 and doc.has_text
    assert [line.id for line in doc.lines] == ["L0001", "L0002", "L0003", "L0004"]
    assert doc.lines[1].text == LINES[1]
    assert doc.lines[0].page == 1 and doc.lines[3].page == 2
    assert doc.numbered().splitlines()[1] == "L0002: " + LINES[1]
    assert doc.by_id["L0003"].text == LINES[2]
    assert doc.text_hash() == pdf_text(make_pdf(LINES + ["Page two line"], pages=2)).text_hash()
    assert doc.numbered(max_lines=2).endswith("[... 2 more lines not shown]")


def test_pdf_without_text_layer_is_flagged_not_fatal():
    doc = pdf_text(make_pdf([]))
    assert not doc.has_text
    assert any("no text layer" in n for n in doc.notes)
    broken = pdf_text(b"%PDF-1.4 garbage")
    assert not broken.has_text and broken.notes


def test_docx_is_read_without_libreoffice():
    doc = docx = extract_document(make_docx(["Probespiel Violoncello", "Dvořák: Sinfonie Nr. 8, 1. Satz, T. 1-18"]), url="https://x.example/liste.docx")
    assert docx.kind == "docx"
    assert [line.text for line in doc.lines] == ["Probespiel Violoncello", "Dvořák: Sinfonie Nr. 8, 1. Satz, T. 1-18"]


def test_legacy_doc_is_skipped_with_a_note_when_soffice_is_missing():
    doc = doc_text(b"\xd0\xcf\x11\xe0", which=lambda name: None)
    assert doc.skipped and "LibreOffice" in doc.notes[0]


def test_legacy_doc_uses_soffice_as_a_separate_process_when_present(tmp_path):
    calls: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        outdir = cmd[cmd.index("--outdir") + 1]
        (tmp_path / "ignored").write_text("")
        with open(f"{outdir}/input.pdf", "wb") as handle:
            handle.write(make_pdf(["Converted line"]))
        return subprocess.CompletedProcess(cmd, 0, b"", b"")

    doc = doc_text(b"\xd0\xcf\x11\xe0", which=lambda name: "/usr/bin/soffice", run=fake_run)
    assert not doc.skipped and doc.kind == "doc"
    assert [line.text for line in doc.lines] == ["Converted line"]
    assert calls[0][:3] == ["/usr/bin/soffice", "--headless", "--norestore"]


def test_document_kind_from_url_or_content_type():
    assert document_kind("https://x/a.PDF?dl=1", None) == "pdf"
    assert document_kind("https://x/a", "application/pdf") == "pdf"
    assert document_kind("https://x/a.docx", None) == "docx"
    assert document_kind("https://x/a", "application/msword") == "doc"
    assert document_kind("https://x/a", "text/html") is None
    unknown = extract_document(b"hello", url="https://x/a", content_type="text/plain")
    assert unknown.skipped


def test_text_documents_and_appended_posting_lines():
    doc = text_document("Section Cello\n\n  deadline 15 November 2026 ")
    assert [line.id for line in doc.lines] == ["L0001", "L0002"]
    append_lines(doc, ["JobPosting validThrough: 2026-11-15"])
    assert doc.lines[-1].id == "L0003"
    assert isinstance(doc, ExtractedText)
