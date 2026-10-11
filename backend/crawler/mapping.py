"""Mapping extracted items to catalogue excerpts (content/catalog/*.json).

Confidence is computed, never asked of the model:
  0.55 · name match (composer · work · movement)
+ 0.25 · bar-range overlap with the excerpt's location or any variant
+ 0.10 · catalogue-number agreement (neutral when one side has none)
+ 0.10 · the item passed verification
Capped at 0.85 when verification failed, at 0.5 when catalogue numbers disagree, and
at 0.89 when two excerpts are nearly tied. ≥ 0.9 maps automatically, 0.6–0.9 goes to
review with the best suggestion, below 0.6 is a "new excerpt candidate".
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .textnorm import (
    composer_tokens,
    fuzzy_contains,
    parse_all_bar_ranges,
    parse_bar_range,
    parse_movement,
    range_overlap,
    significant_tokens,
    surname,
    tokens,
)
from .verify import Verification

log = logging.getLogger("auditioner.crawler.mapping")

AUTO_THRESHOLD = 0.9
REVIEW_THRESHOLD = 0.6


@dataclass(frozen=True)
class CatalogueExcerpt:
    id: str
    instrument: str
    composer: str
    work: str
    catalogue_number: str
    movement_number: int | None
    title: str
    ranges: tuple[tuple[int, int], ...]
    listing_status: str

    @property
    def composer_key(self) -> str:
        return surname(self.composer)


def _bar_points(location: dict[str, Any] | None) -> list[tuple[int, int]]:
    """Structured start/end bars when present, else every range printed in the text."""
    if not isinstance(location, dict):
        return []
    start = (location.get("start") or {}).get("bar")
    end = (location.get("end") or {}).get("bar")
    if isinstance(start, int) and isinstance(end, int) and end >= start:
        return [(start, end)]
    return parse_all_bar_ranges(location.get("text") or "")


def excerpt_from_dict(data: dict[str, Any]) -> CatalogueExcerpt | None:
    try:
        ranges: list[tuple[int, int]] = []
        location = data.get("location") or {}
        if location.get("status") == "verified":
            ranges.extend(_bar_points(location.get("value")))
        for variant in data.get("variants") or []:
            ranges.extend(_bar_points(variant.get("location")))
        movement = data.get("movement") or {}
        number = movement.get("number") if isinstance(movement, dict) else None
        return CatalogueExcerpt(
            id=str(data["id"]),
            instrument=str(data["instrument"]),
            composer=str(data.get("composer") or ""),
            work=str(data.get("work") or ""),
            catalogue_number=str(data.get("catalogueNumber") or ""),
            movement_number=int(number) if isinstance(number, int) else None,
            title=str(data.get("title") or ""),
            ranges=tuple(dict.fromkeys(ranges)),
            listing_status=str(data.get("listingStatus") or "draft"),
        )
    except (KeyError, TypeError, ValueError):
        return None


class Catalogue:
    def __init__(self, excerpts: Iterable[CatalogueExcerpt]) -> None:
        self._by_instrument: dict[str, list[CatalogueExcerpt]] = {}
        for excerpt in excerpts:
            self._by_instrument.setdefault(excerpt.instrument, []).append(excerpt)

    @classmethod
    def load(cls, directory: Path | str, *, include_drafts: bool = True) -> Catalogue:
        excerpts: list[CatalogueExcerpt] = []
        directory = Path(directory)
        if directory.is_dir():
            for path in sorted(directory.glob("*.json")):
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, ValueError) as exc:
                    log.warning("catalogue file %s unreadable: %s", path.name, exc)
                    continue
                for raw in data.get("excerpts") or []:
                    excerpt = excerpt_from_dict(raw)
                    if excerpt is None:
                        continue
                    if not include_drafts and excerpt.listing_status != "published":
                        continue
                    excerpts.append(excerpt)
        else:
            log.warning("catalogue directory %s not found — nothing will map", directory)
        return cls(excerpts)

    def for_instrument(self, instrument: str) -> list[CatalogueExcerpt]:
        return list(self._by_instrument.get(instrument, []))

    def __len__(self) -> int:
        return sum(len(v) for v in self._by_instrument.values())

    @property
    def instruments(self) -> list[str]:
        return sorted(self._by_instrument)


@dataclass
class Mapping:
    excerpt_id: str | None
    confidence: float
    bucket: str  # auto | review | new_candidate
    reasons: list[str] = field(default_factory=list)
    candidates: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "excerptId": self.excerpt_id,
            "confidence": round(self.confidence, 3),
            "bucket": self.bucket,
            "reasons": list(self.reasons),
            "candidates": [dict(c) for c in self.candidates[:5]],
        }


def _number_tokens(text: str) -> set[str]:
    return {t for t in tokens(text) if t.isdigit()}


def _work_score(item_work: str, excerpt_work: str) -> float:
    item_tokens = significant_tokens(item_work)
    excerpt_tokens = tokens(excerpt_work)
    if not item_tokens or not excerpt_tokens:
        return 0.0
    item_numbers, excerpt_numbers = _number_tokens(item_work), _number_tokens(excerpt_work)
    if item_numbers and excerpt_numbers and not (item_numbers & excerpt_numbers):
        return 0.0  # "Symphony No. 5" is not "Symphony No. 7"
    matched = sum(1 for tok in item_tokens if fuzzy_contains(excerpt_tokens, tok))
    score = matched / len(item_tokens)
    if item_numbers and not (item_numbers & excerpt_numbers):
        score *= 0.5  # item names a number the excerpt lacks
    if excerpt_numbers and not item_numbers:
        score *= 0.7  # excerpt is "No. 5", item just says "Symphony"
    return score


def _composer_score(item_composer: str, excerpt: CatalogueExcerpt) -> float:
    if not item_composer:
        return 0.0
    excerpt_tokens = tokens(excerpt.composer)
    return 1.0 if any(fuzzy_contains(excerpt_tokens, tok) for tok in composer_tokens(item_composer)) else 0.0


def _movement_factor(item: dict[str, Any], excerpt: CatalogueExcerpt) -> tuple[float, str]:
    item_movement = parse_movement(item.get("movement") or "")
    if item_movement is None and excerpt.movement_number is None:
        return 1.0, "no movement on either side"
    if item_movement is None or excerpt.movement_number is None:
        return 0.75, "movement given on one side only"
    if item_movement == excerpt.movement_number:
        return 1.0, "movement matches"
    return 0.2, f"movement differs ({item_movement} vs {excerpt.movement_number})"


def _catalogue_number_factor(item_number: str, excerpt_number: str) -> tuple[float, bool]:
    """(score 0..1, conflict?)"""
    a, b = tokens(item_number), tokens(excerpt_number)
    if not a or not b:
        return 0.5, False
    a_digits, b_digits = {t for t in a if t.isdigit()}, {t for t in b if t.isdigit()}
    if a_digits and b_digits:
        return (1.0, False) if a_digits == b_digits else (0.0, True)
    return (1.0, False) if a == b else (0.0, True)


def _item_range(item: dict[str, Any]) -> tuple[int, int] | None:
    location = item.get("location") or {}
    if location.get("type") == "measures":
        start, end = int(location.get("startBar") or 0), int(location.get("endBar") or 0)
        if start >= 1 and end >= start:
            return start, end
    return parse_bar_range(" ".join([location.get("startText") or "", location.get("endText") or ""]))


def score_candidate(item: dict[str, Any], verification: Verification, excerpt: CatalogueExcerpt) -> tuple[float, list[str]]:
    reasons: list[str] = []
    composer = _composer_score(item.get("composer") or "", excerpt)
    if composer == 0.0:
        return 0.0, ["composer does not match"]
    work = _work_score(item.get("work") or "", excerpt.work)
    if work == 0.0:
        return 0.0, ["work does not match"]
    movement, movement_reason = _movement_factor(item, excerpt)
    reasons.append(movement_reason)
    name = composer * work * movement

    item_range = _item_range(item)
    if item_range and excerpt.ranges:
        overlap = max(range_overlap(item_range, r) for r in excerpt.ranges)
        reasons.append(f"bar overlap {overlap:.2f} for {item_range[0]}-{item_range[1]}")
    elif item_range or excerpt.ranges:
        overlap = 0.5
        reasons.append("bars known on one side only")
    else:
        overlap = 0.5
        reasons.append("no bar numbers on either side")

    catalogue_number, conflict = _catalogue_number_factor(item.get("catalogueNumber") or "", excerpt.catalogue_number)
    if conflict:
        reasons.append(f"catalogue number differs ({item.get('catalogueNumber')} vs {excerpt.catalogue_number})")
    verified = 1.0 if verification.ok else 0.0
    confidence = 0.55 * name + 0.25 * overlap + 0.10 * catalogue_number + 0.10 * verified
    if conflict:
        confidence = min(confidence, 0.5)
    if not verification.ok:
        confidence = min(confidence, 0.85)
        reasons.append("item failed verification — review required")
    return round(confidence, 4), reasons


def map_item(item: dict[str, Any], verification: Verification, catalogue: Catalogue, instrument: str) -> Mapping:
    if item.get("category") in ("sight_reading", "other"):
        return Mapping(None, 0.0, "new_candidate", ["not an excerpt or solo item"])
    excerpts = catalogue.for_instrument(instrument)
    if not excerpts:
        return Mapping(None, 0.0, "new_candidate", [f"no catalogue for instrument '{instrument}'"])
    scored: list[tuple[float, CatalogueExcerpt, list[str]]] = []
    for excerpt in excerpts:
        confidence, reasons = score_candidate(item, verification, excerpt)
        if confidence > 0:
            scored.append((confidence, excerpt, reasons))
    scored.sort(key=lambda entry: -entry[0])
    candidates = [{"excerptId": e.id, "confidence": round(c, 3), "title": e.title} for c, e, _ in scored[:5]]
    if not scored:
        return Mapping(None, 0.0, "new_candidate", ["no catalogue excerpt shares composer and work"], candidates)
    best_confidence, best, reasons = scored[0]
    if len(scored) > 1 and scored[1][0] >= REVIEW_THRESHOLD and scored[1][0] >= best_confidence - 0.05:
        best_confidence = min(best_confidence, 0.89)
        reasons = reasons + [f"nearly tied with {scored[1][1].id}"]
    if best_confidence >= AUTO_THRESHOLD:
        return Mapping(best.id, best_confidence, "auto", reasons, candidates)
    if best_confidence >= REVIEW_THRESHOLD:
        return Mapping(best.id, best_confidence, "review", reasons, candidates)
    return Mapping(None, best_confidence, "new_candidate", reasons, candidates)
