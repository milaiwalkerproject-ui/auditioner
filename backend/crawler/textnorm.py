"""Text normalisation shared by verification and catalogue mapping.

Everything here is deterministic and diacritic-insensitive: "Dvořák" and "Dvorak"
compare equal, "Tschaikowsky" is close enough to "Tchaikovsky", "mm. 1–106" parses
to (1, 106). None of it guesses facts — it only compares text the source contains.
"""

from __future__ import annotations

import difflib
import re
import unicodedata
from typing import Iterable

_SPECIAL = str.maketrans(
    {
        "ß": "ss",
        "ø": "o",
        "Ø": "o",
        "æ": "ae",
        "Æ": "ae",
        "œ": "oe",
        "Œ": "oe",
        "ł": "l",
        "Ł": "l",
        "đ": "d",
        "Đ": "d",
        "þ": "th",
        "ð": "d",
        "ı": "i",
        "’": "'",
        "‘": "'",
        "–": "-",
        "—": "-",
        "‐": "-",
        "−": "-",
    }
)

STOPWORDS = frozenset(
    {
        "the", "and", "of", "in", "for", "from", "to", "with", "a", "an", "no", "op", "nr", "n",
        "mvt", "mov", "movement", "mm", "bar", "bars", "measure", "measures", "beginning",
        "end", "der", "die", "das", "und", "von", "für", "la", "le", "les", "des", "du", "et",
        "il", "di", "e", "del", "della", "en", "y", "de", "satz",
    }
)

ROMAN = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10}
ORDINAL_WORDS = {
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "erster": 1, "zweiter": 2, "dritter": 3, "vierter": 4, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5,
}


def strip_diacritics(text: str) -> str:
    text = text.translate(_SPECIAL)
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def normalise(text: str) -> str:
    """Lower-case ASCII with single spaces; punctuation becomes a space."""
    text = strip_diacritics(text or "").lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def tokens(text: str) -> list[str]:
    return normalise(text).split()


def significant_tokens(text: str, *, min_len: int = 3) -> list[str]:
    out: list[str] = []
    for tok in tokens(text):
        if tok in STOPWORDS:
            continue
        if len(tok) >= min_len or tok.isdigit():
            out.append(tok)
    return out


def token_matches(needle: str, candidate: str) -> bool:
    """Is `candidate` (a token from the source) a plausible spelling of `needle`?"""
    if needle == candidate:
        return True
    if needle.isdigit() or candidate.isdigit():
        return False
    shorter, longer = sorted((needle, candidate), key=len)
    if len(shorter) >= 3 and longer.startswith(shorter):
        return True  # "beeth" ~ "beethoven", "sym" ~ "symphony"
    if len(shorter) >= 5:
        return difflib.SequenceMatcher(None, needle, candidate).ratio() >= 0.8
    return False


def fuzzy_contains(haystack_tokens: Iterable[str], needle: str) -> bool:
    return any(token_matches(needle, tok) for tok in haystack_tokens)


def surname(composer: str) -> str:
    """The most useful token of a composer name: the last non-particle token."""
    parts = [t for t in tokens(composer) if t not in {"van", "von", "de", "da", "di", "le", "la", "jr", "sr"}]
    if not parts:
        return ""
    # "Strauss, Richard" → tokens ["strauss", "richard"]; prefer the token before a comma.
    if "," in composer:
        head = tokens(composer.split(",", 1)[0])
        if head:
            return head[-1]
    return parts[-1]


def composer_tokens(composer: str) -> list[str]:
    """Tokens that identify a composer: surname first, then other long tokens."""
    name = surname(composer)
    others = [t for t in significant_tokens(composer, min_len=4) if t != name]
    return ([name] if name else []) + others


_RANGE_PATTERNS = [
    # "mm. 1–106", "bars 49-59", "m. 8 to m. 90", "T. 1-20", "measures 3 through 20"
    re.compile(
        r"(?:\b(?:mm?|bars?|measures?|t|takte?|b|mes|mis|bb)\b\.?\s*)?"
        r"(?P<start>\d{1,4})\s*(?:-|–|—|to|through|bis|a|à|~|al)\s*(?:(?:mm?|bars?|measures?|t|takt|b|m)\b\.?\s*)?(?P<end>\d{1,4})\b",
        re.IGNORECASE,
    ),
]
_SINGLE_PATTERN = re.compile(r"\b(?:mm?|bars?|measures?|t|takt|b)\b\.?\s*(?P<bar>\d{1,4})\b", re.IGNORECASE)
_PICKUP = re.compile(r"\b(pickup|pick-up|upbeat|auftakt|anacrusis)\b", re.IGNORECASE)


def parse_bar_range(text: str) -> tuple[int, int] | None:
    """Parse 'mm. 1–106' style ranges. Returns None when the text does not carry
    two bar numbers (a rehearsal-mark range, 'beginning to end', ...)."""
    if not text:
        return None
    cleaned = text.translate(_SPECIAL)
    for pattern in _RANGE_PATTERNS:
        match = pattern.search(cleaned)
        if match:
            start, end = int(match.group("start")), int(match.group("end"))
            if start <= end and end < 10000:
                return start, end
    return None


def parse_single_bar(text: str) -> int | None:
    if not text:
        return None
    match = _SINGLE_PATTERN.search(text.translate(_SPECIAL))
    return int(match.group("bar")) if match else None


def parse_movement(text: str) -> int | None:
    """'II', 'Mvt. 2', '2nd movement', 'Satz 3', 'Finale' → number (Finale is unknown)."""
    if not text:
        return None
    for tok in re.findall(r"[A-Za-z0-9]+", text):
        low = tok.lower()
        if low in ROMAN:
            return ROMAN[low]
        if low in ORDINAL_WORDS:
            return ORDINAL_WORDS[low]
        if low.isdigit() and 1 <= int(low) <= 12:
            return int(low)
    return None


def range_overlap(a: tuple[int, int], b: tuple[int, int]) -> float:
    """Intersection over union of two closed bar ranges, 0..1."""
    lo = max(a[0], b[0])
    hi = min(a[1], b[1])
    if hi < lo:
        return 0.0
    inter = hi - lo + 1
    union = max(a[1], b[1]) - min(a[0], b[0]) + 1
    return inter / union if union else 0.0
