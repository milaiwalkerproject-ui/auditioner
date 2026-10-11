"""Contact details never reach the database (docs/BOT.md).

Email addresses and phone numbers are removed from every piece of text the crawler
stores — the verbatim source lines of an item, notes, positions, link texts — by
pattern, in code, after extraction and verification. Staff names cannot be told
from composers' names by a pattern; they are kept out by the extraction
instructions (llm.py, rule 11) and by the person who reviews every list before it
is shown.

Bar numbers, catalogue numbers and dates must survive. The phone patterns therefore
need a label ("Tel."), a leading "+", brackets around an area code, the 3-3-4
grouping of North American numbers, or a leading-zero trunk code with at least three
groups — never a plain "1-106", "K. 550" or "2026-11-15".
"""

from __future__ import annotations

import re
from typing import Any

EMAIL_PLACEHOLDER = "[email removed]"
PHONE_PLACEHOLDER = "[phone removed]"

_EMAIL = re.compile(
    r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}"
)
# "name (at) orchestra (dot) org" — a common way to hide an address from harvesters.
_EMAIL_OBFUSCATED = re.compile(
    r"[A-Za-z0-9._%+\-]+\s*[\[(]\s*at\s*[\])]\s*[A-Za-z0-9.\-]+\s*[\[(]\s*dot\s*[\])]\s*[A-Za-z]{2,}",
    re.IGNORECASE,
)
_PHONES = (
    # A labelled number in any format: "Tel. 030-1234567", "Phone: 555 010 2030", "Fon +49 ..."
    re.compile(
        r"\b(?:tel|telefon|telephone|phone|fax|mobile|mobil|cell|fon)\b\.?\s*:?\s*\+?[\d(][\d\s()./\-]{5,}\d",
        re.IGNORECASE,
    ),
    # International: +1 212 555 0100, +44 (0)20 7123 4567, +49 30 12345678
    re.compile(r"\+\s?\d{1,3}(?:[\s().\-]*\d){7,13}"),
    # Bracketed area code: (661) 323-7928, (02) 9876 5432
    re.compile(r"\(\d{2,5}\)[\s.\-]*\d(?:[\s.\-]*\d){5,10}"),
    # North American 3-3-4: 661-323-7928, 661.323.7928, 661 323 7928
    re.compile(r"(?<![\d\-])\d{3}[\s.\-]\d{3}[\s.\-]\d{4}(?![\d\-])"),
    # Trunk-code groups: 030 1234 5678, 0171/123 45 67 (three or more groups, leading 0)
    re.compile(r"(?<![\d\-/.])0\d{2,4}[\s/]\d{3,}(?:[\s/\-]\d{2,})+(?![\d\-/.])"),
)


def redact_text(text: str) -> tuple[str, int]:
    """Return (text without contact details, how many were removed)."""
    if not text:
        return text, 0
    count = 0
    text, n = _EMAIL.subn(EMAIL_PLACEHOLDER, text)
    count += n
    text, n = _EMAIL_OBFUSCATED.subn(EMAIL_PLACEHOLDER, text)
    count += n
    for pattern in _PHONES:
        text, n = pattern.subn(PHONE_PLACEHOLDER, text)
        count += n
    return text, count


def redact_value(value: Any) -> tuple[Any, int]:
    """Walk strings, lists and dicts; everything else is returned unchanged."""
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        out: list[Any] = []
        total = 0
        for item in value:
            cleaned, n = redact_value(item)
            out.append(cleaned)
            total += n
        return out, total
    if isinstance(value, dict):
        result: dict[Any, Any] = {}
        total = 0
        for key, item in value.items():
            cleaned, n = redact_value(item)
            result[key] = cleaned
            total += n
        return result, total
    return value, 0


def contains_contact(text: str) -> bool:
    return redact_text(text)[1] > 0
