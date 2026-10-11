"""Deterministic checks of what the model extracted against the lines it cited.

The honesty contract in code: an item is `ok` only when its cited lines exist and
carry the composer, the work and the bar numbers it claims. A date survives only if
its cited lines carry it. Model confidence is never consulted.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from .documents import SourceLine
from .textnorm import composer_tokens, fuzzy_contains, significant_tokens, tokens

HARD_FLAGS = frozenset(
    {
        "no_source_lines",
        "line_missing",
        "composer_not_in_cited_lines",
        "work_not_in_cited_lines",
        "bars_invalid",
        "bars_not_in_cited_lines",
    }
)

MONTHS = {
    1: ("january", "jan", "januar", "janvier", "gennaio", "enero", "januari", "1月"),
    2: ("february", "feb", "februar", "février", "fevrier", "febbraio", "febrero", "februari", "2月"),
    3: ("march", "mar", "märz", "marz", "mars", "marzo", "maart", "3月"),
    4: ("april", "apr", "avril", "aprile", "abril", "4月"),
    5: ("may", "mai", "maggio", "mayo", "mei", "5月"),
    6: ("june", "jun", "juni", "juin", "giugno", "junio", "6月"),
    7: ("july", "jul", "juli", "juillet", "luglio", "julio", "7月"),
    8: ("august", "aug", "août", "aout", "agosto", "augustus", "8月"),
    9: ("september", "sep", "sept", "septembre", "settembre", "septiembre", "9月"),
    10: ("october", "oct", "oktober", "octobre", "ottobre", "octubre", "10月"),
    11: ("november", "nov", "novembre", "noviembre", "11月"),
    12: ("december", "dec", "dezember", "décembre", "decembre", "dicembre", "diciembre", "12月"),
}


@dataclass
class Verification:
    ok: bool = True
    flags: list[str] = field(default_factory=list)
    cited_line_ids: list[str] = field(default_factory=list)
    cited_text: str = ""
    notes: list[str] = field(default_factory=list)

    def flag(self, name: str, note: str | None = None) -> None:
        if name not in self.flags:
            self.flags.append(name)
        if note:
            self.notes.append(note)
        if name in HARD_FLAGS:
            self.ok = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "flags": list(self.flags),
            "citedLineIds": list(self.cited_line_ids),
            "notes": list(self.notes),
        }


def _cited(ids: list[str], lines: dict[str, SourceLine], verification: Verification) -> str:
    texts: list[str] = []
    for line_id in ids:
        line = lines.get(line_id)
        if line is None:
            verification.flag("line_missing", f"cited line {line_id} does not exist")
            continue
        verification.cited_line_ids.append(line_id)
        texts.append(line.text)
    return "\n".join(texts)


def verify_item(item: dict[str, Any], lines: dict[str, SourceLine]) -> Verification:
    verification = Verification()
    ids = item.get("sourceLineIds") or []
    if not ids:
        verification.flag("no_source_lines", "item cites no source lines")
        return verification
    cited = _cited(ids, lines, verification)
    verification.cited_text = cited
    cited_tokens = tokens(cited)
    if not cited_tokens:
        verification.flag("no_source_lines", "cited lines are empty")
        return verification

    composer = item.get("composer") or ""
    if composer:
        if not any(fuzzy_contains(cited_tokens, tok) for tok in composer_tokens(composer)):
            verification.flag("composer_not_in_cited_lines", f"'{composer}' is not in the cited lines")
    elif item.get("category") in ("excerpt", "solo"):
        verification.flag("composer_missing", "no composer given")

    work = item.get("work") or ""
    catalogue_number = item.get("catalogueNumber") or ""
    if work:
        work_tokens = significant_tokens(work)
        number_tokens = [t for t in tokens(catalogue_number) if t.isdigit()]
        found = any(fuzzy_contains(cited_tokens, tok) for tok in work_tokens)
        found = found or (bool(number_tokens) and all(t in cited_tokens for t in number_tokens))
        if not found and work_tokens:
            verification.flag("work_not_in_cited_lines", f"'{work}' is not in the cited lines")
    if catalogue_number:
        digits = [t for t in tokens(catalogue_number) if t.isdigit()]
        if digits and not all(d in cited_tokens for d in digits):
            verification.flag("catalogue_number_not_in_cited_lines", f"'{catalogue_number}' is not in the cited lines")

    location = item.get("location") or {}
    start, end = int(location.get("startBar") or 0), int(location.get("endBar") or 0)
    kind = location.get("type") or "unknown"
    if kind == "measures":
        if start < 1 or end < start:
            verification.flag("bars_invalid", f"bar range {start}-{end} does not parse (end must be ≥ start ≥ 1)")
        else:
            numbers = set(re.findall(r"\d+", cited))
            if str(start) not in numbers or str(end) not in numbers:
                verification.flag("bars_not_in_cited_lines", f"bars {start}-{end} are not printed in the cited lines")
    elif start or end:
        verification.flag("bars_without_measures_type", "bar numbers given but location type is not 'measures'")
    return verification


def verify_dated(dated: dict[str, Any], lines: dict[str, SourceLine]) -> tuple[str, list[str]]:
    """Return (value or "", flags). The value survives only when the cited lines carry it."""
    value = dated.get("value") or ""
    if not value:
        return "", []
    ids = dated.get("sourceLineIds") or []
    cited = "\n".join(lines[i].text for i in ids if i in lines)
    if not cited:
        return "", ["date_without_source_lines"]
    year, month, day = value.split("-")
    low = cited.lower()
    month_num = int(month)
    day_num = int(day)
    year_ok = year in low or value in low
    month_words = MONTHS.get(month_num, ())
    numeric_forms = {
        f"{day_num}.{month_num}.{year}", f"{day_num:02d}.{month_num:02d}.{year}", f"{day_num}/{month_num}/{year}",
        f"{day_num:02d}/{month_num:02d}/{year}", f"{month_num}/{day_num}/{year}", f"{month_num:02d}/{day_num:02d}/{year}",
        f"{year}-{month:0>2}-{day:0>2}", f"{year}/{month_num:02d}/{day_num:02d}", f"{year}年{month_num}月{day_num}日",
        f"{day_num}.{month_num}.{year[2:]}", f"{day_num:02d}.{month_num:02d}.{year[2:]}", f"{day_num}/{month_num}/{year[2:]}",
    }
    day_ok = bool(re.search(rf"(?<!\d){day_num}(?!\d)", low))
    month_ok = any(re.search(rf"(?<![a-z]){re.escape(w)}", low) for w in month_words)
    if any(form in low for form in numeric_forms):
        return value, []
    if year_ok and day_ok and month_ok:
        return value, []
    return "", ["date_not_in_cited_lines"]


def verify_vacancy(vacancy: dict[str, Any], lines: dict[str, SourceLine]) -> tuple[dict[str, Any], list[Verification], list[str]]:
    """Verify a coerced vacancy. Returns (cleaned vacancy, per-item verifications,
    vacancy-level flags). Dates that fail verification are blanked, not kept."""
    cleaned = dict(vacancy)
    flags: list[str] = []
    deadline, deadline_flags = verify_dated(vacancy.get("applicationDeadline") or {}, lines)
    cleaned["applicationDeadline"] = {"value": deadline, "sourceLineIds": list((vacancy.get("applicationDeadline") or {}).get("sourceLineIds") or [])}
    flags.extend(f"deadline:{f}" for f in deadline_flags)
    dates: list[dict[str, Any]] = []
    for dated in vacancy.get("auditionDates") or []:
        value, date_flags = verify_dated(dated, lines)
        if value:
            dates.append({"value": value, "sourceLineIds": list(dated.get("sourceLineIds") or [])})
        flags.extend(f"auditionDate:{f}" for f in date_flags)
    cleaned["auditionDates"] = dates
    verifications = [verify_item(item, lines) for item in vacancy.get("items") or []]
    if not cleaned.get("position"):
        flags.append("position_missing")
    if cleaned.get("instrument") in (None, "", "other"):
        flags.append("instrument_unknown")
    return cleaned, verifications, flags
