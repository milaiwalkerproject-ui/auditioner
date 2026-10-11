"""HTML handling: the main text of a page (for hashing and extraction), the links
worth following, and schema.org JobPosting data when a page carries it.

Nothing here runs scripts or loads anything — it is plain parsing of the HTML the
server sent.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Iterable
from urllib.parse import urljoin, urlsplit, urlunsplit

from bs4 import BeautifulSoup, Tag

from .policy import is_document_url

REMOVE_TAGS = (
    "script", "style", "noscript", "template", "svg", "iframe", "form", "nav", "header", "footer",
    "aside", "button", "select", "input", "textarea", "canvas", "video", "audio", "picture",
)
REMOVE_ROLES = frozenset({"navigation", "banner", "contentinfo", "search", "menu", "menubar", "dialog"})
REMOVE_CLASS_HINTS = ("cookie", "breadcrumb", "sidebar", "share", "social", "menu", "navbar", "nav-", "skip")

# Words (several languages) that make a link worth a look.
AUDITION_WORDS = (
    "audition", "auditions", "vacanc", "repertoire", "repertory", "répertoire", "repertorio",
    "excerpt", "probespiel", "stellenausschreibung", "ausschreibung", "stelle", "audizion", "concorso",
    "bando", "concours", "audición", "audicion", "auditie", "vacature", "オーディション", "募集", "오디션",
    "채용", "employment", "job", "career", "opportunit", "opening", "position", "list", "liste",
    "候補", "试音", "試音", "招聘", "甄選",
)
PAGE_WORDS = (
    "audition", "vacanc", "probespiel", "stellenausschreibung", "ausschreibung", "audizion", "concorso",
    "concours", "audición", "audicion", "auditie", "vacature", "オーディション", "募集", "오디션", "채용",
    "employment", "job", "career", "opportunit", "opening", "work with us", "join", "试音", "試音", "招聘",
)
STRONG_DOCUMENT_WORDS = (
    "repertoire", "repertory", "répertoire", "repertorio", "excerpt", "probespiel", "rep list", "replist",
    "audition list", "audition-list", "excerpts", "orchesterstellen", "stellen", "曲目", "課題曲", "抜粋",
)

_DATE_PATTERNS = [
    re.compile(r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\b"),
    re.compile(r"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"),
    re.compile(
        r"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?,?\s+\d{4}\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b", re.IGNORECASE),
]


@dataclass(frozen=True)
class Link:
    url: str
    text: str
    kind: str  # "document" | "page"
    strong: bool = False


@dataclass
class JobPosting:
    title: str = ""
    date_posted: str = ""
    valid_through: str = ""
    organisation: str = ""
    url: str = ""
    employment_type: str = ""
    description: str = ""
    raw: dict[str, Any] = field(default_factory=dict)

    def to_lines(self) -> list[str]:
        lines: list[str] = []
        if self.title:
            lines.append(f"JobPosting title: {self.title}")
        if self.organisation:
            lines.append(f"JobPosting hiringOrganization: {self.organisation}")
        if self.date_posted:
            lines.append(f"JobPosting datePosted: {self.date_posted}")
        if self.valid_through:
            lines.append(f"JobPosting validThrough: {self.valid_through}")
        if self.employment_type:
            lines.append(f"JobPosting employmentType: {self.employment_type}")
        if self.url:
            lines.append(f"JobPosting url: {self.url}")
        for line in self.description.splitlines():
            line = line.strip()
            if line:
                lines.append(f"JobPosting description: {line}")
        return lines


def _soup(html: str | bytes) -> BeautifulSoup:
    return BeautifulSoup(html, "html.parser")


def _looks_like_chrome(tag: Tag) -> bool:
    role = (tag.get("role") or "").strip().lower()
    if role in REMOVE_ROLES:
        return True
    classes = " ".join(tag.get("class") or []).lower() + " " + (tag.get("id") or "").lower()
    return any(hint in classes for hint in REMOVE_CLASS_HINTS)


def main_text(html: str | bytes) -> str:
    """Readable text of the content area, one block per line, without site chrome."""
    soup = _soup(html)
    for tag in soup.find_all(REMOVE_TAGS):
        tag.decompose()
    for tag in list(soup.find_all(True)):
        if isinstance(tag, Tag) and tag.parent is not None and _looks_like_chrome(tag):
            tag.decompose()
    root: Tag | None = soup.find("main") or soup.find(attrs={"role": "main"}) or soup.find("article") or soup.body or soup
    text = root.get_text("\n") if root is not None else ""
    lines: list[str] = []
    previous = None
    for raw in text.splitlines():
        line = re.sub(r"[ \t ]+", " ", raw).strip()
        if not line or line == previous:
            continue
        lines.append(line)
        previous = line
    return "\n".join(lines)


def strip_dates(text: str) -> str:
    for pattern in _DATE_PATTERNS:
        text = pattern.sub(" ", text)
    return text


def content_hash(text: str) -> str:
    """Hash of the page text with dates and whitespace removed, so 'last updated
    today' footers do not count as a change."""
    cleaned = strip_dates(text.lower())
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return hashlib.sha256(cleaned.encode("utf-8")).hexdigest()


def bytes_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _clean_url(base_url: str, href: str) -> str | None:
    href = (href or "").strip()
    if not href or href.startswith(("#", "mailto:", "tel:", "javascript:", "data:")):
        return None
    try:
        absolute = urljoin(base_url, href)
        parts = urlsplit(absolute)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    return urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, ""))


def _matches(words: Iterable[str], *texts: str) -> bool:
    haystack = " ".join(t.lower() for t in texts if t)
    return any(word in haystack for word in words)


def discover_links(html: str | bytes, base_url: str) -> list[Link]:
    """Documents (pdf/doc/docx) and same-host pages whose text or address suggests
    auditions. Strong document matches (repertoire, excerpts, Probespiel) first."""
    soup = _soup(html)
    base_host = (urlsplit(base_url).hostname or "").lower()
    seen: set[str] = set()
    documents: list[Link] = []
    pages: list[Link] = []
    for anchor in soup.find_all("a", href=True):
        url = _clean_url(base_url, anchor["href"])
        if url is None or url in seen or url.split("#")[0] == base_url:
            continue
        text = " ".join(anchor.get_text(" ").split())
        title = anchor.get("title") or ""
        path = urlsplit(url).path
        if is_document_url(url):
            if _matches(AUDITION_WORDS, text, title, path):
                strong = _matches(STRONG_DOCUMENT_WORDS, text, title, path)
                documents.append(Link(url=url, text=text, kind="document", strong=strong))
                seen.add(url)
        else:
            host = (urlsplit(url).hostname or "").lower()
            if host == base_host and _matches(PAGE_WORDS, text, title, path):
                pages.append(Link(url=url, text=text, kind="page", strong=_matches(("audition", "probespiel", "vacanc"), text, path)))
                seen.add(url)
    documents.sort(key=lambda link: (not link.strong))
    pages.sort(key=lambda link: (not link.strong))
    return documents + pages


def _walk_jsonld(node: Any) -> Iterable[dict[str, Any]]:
    if isinstance(node, list):
        for item in node:
            yield from _walk_jsonld(item)
    elif isinstance(node, dict):
        yield node
        for key in ("@graph", "mainEntity", "itemListElement", "hasPart"):
            if key in node:
                yield from _walk_jsonld(node[key])


def _is_job_posting(node: dict[str, Any]) -> bool:
    kind = node.get("@type")
    kinds = kind if isinstance(kind, list) else [kind]
    return any(isinstance(k, str) and k.lower() == "jobposting" for k in kinds)


def _text(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for key in ("name", "@value", "text"):
            if isinstance(value.get(key), str):
                return value[key].strip()
    if isinstance(value, list) and value:
        return _text(value[0])
    return ""


def parse_job_postings(html: str | bytes) -> list[JobPosting]:
    soup = _soup(html)
    postings: list[JobPosting] = []
    for script in soup.find_all("script", attrs={"type": re.compile(r"application/ld\+json", re.I)}):
        raw = script.string or script.get_text() or ""
        raw = raw.strip()
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except ValueError:
            try:
                data = json.loads(re.sub(r",\s*([}\]])", r"\1", raw))  # tolerate trailing commas
            except ValueError:
                continue
        for node in _walk_jsonld(data):
            if not _is_job_posting(node):
                continue
            description_html = node.get("description") or ""
            description = _soup(description_html).get_text("\n") if isinstance(description_html, str) else ""
            postings.append(
                JobPosting(
                    title=_text(node.get("title")) or _text(node.get("name")),
                    date_posted=_text(node.get("datePosted")),
                    valid_through=_text(node.get("validThrough")),
                    organisation=_text(node.get("hiringOrganization")),
                    url=_text(node.get("url")),
                    employment_type=_text(node.get("employmentType")),
                    description="\n".join(l.strip() for l in description.splitlines() if l.strip()),
                    raw=node,
                )
            )
    return postings
