"""Which addresses the bot may fetch at all (PLAN F1, CLAUDE.md "never" list).

* Only http(s).
* Orchestras' own hosts (from the registry): pages and documents.
* Documents (.pdf/.doc/.docx) on other hosts only when linked from an orchestra's
  own page — repertoire lists often live on a CDN or on assets.muvac.com.
* Aggregators and social networks are refused always, with one exception written
  into the rules: assets.muvac.com for a document the orchestra itself linked to.
  muvac.com listing pages are never read.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from urllib.parse import urlsplit

# Hosts (and all their subdomains) the bot never reads — aggregators, job boards,
# social networks, score libraries. Keep in step with docs/BOT.md.
REFUSED_HOSTS: frozenset[str] = frozenset(
    {
        # Aggregators / job boards (PLAN F1)
        "musicalchairs.info",
        "muvac.com",
        "orchestraplan.com",
        "orchestraplan.de",
        "auditioncafe.com",
        "internationalmusician.org",
        "afm.org",
        "americanorchestras.org",
        "musicchairs.com",
        "berufsorchester.de",
        "symphony.org",
        "theviolinchannel.com",
        "cellobello.org",
        "harpcolumn.com",
        "indeed.com",
        "glassdoor.com",
        # Social networks / video
        "facebook.com",
        "fb.com",
        "instagram.com",
        "twitter.com",
        "x.com",
        "linkedin.com",
        "youtube.com",
        "youtu.be",
        "tiktok.com",
        # Score libraries — never fetched by the bot (PLAN D1)
        "imslp.org",
        "imslp.eu",
    }
)

# Refused hosts that become acceptable for a *document* the orchestra's own page links to.
ALLOWED_DOCUMENT_HOSTS_VIA_LINK: frozenset[str] = frozenset({"assets.muvac.com"})

DOCUMENT_EXTENSIONS = (".pdf", ".doc", ".docx")


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: str

    def __bool__(self) -> bool:  # pragma: no cover - convenience
        return self.allowed


def normalise_host(host: str | None) -> str:
    host = (host or "").lower().strip().strip(".")
    if host.startswith("www."):
        host = host[4:]
    return host


def host_matches(host: str, base: str) -> bool:
    host, base = normalise_host(host), normalise_host(base)
    return bool(base) and (host == base or host.endswith("." + base))


def is_document_url(url: str) -> bool:
    path = urlsplit(url).path.lower()
    return path.endswith(DOCUMENT_EXTENSIONS)


class HostPolicy:
    def __init__(self, registry_hosts: Iterable[str]) -> None:
        self._hosts = frozenset(normalise_host(h) for h in registry_hosts if h)

    @property
    def registry_hosts(self) -> frozenset[str]:
        return self._hosts

    def is_registry_host(self, host: str | None) -> bool:
        if not host:
            return False
        return any(host_matches(host, base) for base in self._hosts)

    def is_refused_host(self, host: str | None) -> bool:
        if not host:
            return True
        return any(host_matches(host, refused) for refused in REFUSED_HOSTS)

    def check(self, url: str, *, linked_from: str | None = None, kind: str = "page") -> Decision:
        """`kind` is "page" (HTML) or "document" (pdf/doc/docx). `linked_from` is the
        page on which the link was found, if any."""
        try:
            parts = urlsplit(url)
        except ValueError:
            return Decision(False, "unparseable address")
        if parts.scheme not in ("http", "https"):
            return Decision(False, f"scheme '{parts.scheme or '-'}' is not http(s)")
        host = normalise_host(parts.hostname)
        if not host:
            return Decision(False, "no host")
        if parts.username or parts.password:
            return Decision(False, "credentials in address")

        from_registry_page = bool(linked_from) and self.is_registry_host(normalise_host(urlsplit(linked_from).hostname))

        if self.is_refused_host(host):
            if (
                kind == "document"
                and from_registry_page
                and any(host_matches(host, ok) for ok in ALLOWED_DOCUMENT_HOSTS_VIA_LINK)
            ):
                return Decision(True, "document on an allowed asset host, linked from the orchestra's own page")
            return Decision(False, f"{host} is an aggregator or social network the bot never reads")

        if self.is_registry_host(host):
            return Decision(True, "orchestra's own host")

        if kind == "document" and from_registry_page:
            return Decision(True, "document linked from the orchestra's own page")

        if kind == "document":
            return Decision(False, f"{host} is not an orchestra host and the document was not linked from one")
        return Decision(False, f"{host} is not in the registry")
