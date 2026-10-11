"""Email addresses and phone numbers go; bar numbers, catalogue numbers and dates stay."""

from __future__ import annotations

import pytest

from crawler.redact import (
    EMAIL_PLACEHOLDER,
    PHONE_PLACEHOLDER,
    contains_contact,
    redact_text,
    redact_value,
)


def test_emails_are_removed():
    text, n = redact_text("Send to auditions@example-phil.org or jane.doe+x@mail.example.co.uk by Friday")
    assert n == 2 and "@" not in text and text.count(EMAIL_PLACEHOLDER) == 2 and text.endswith("by Friday")


def test_obfuscated_emails_are_removed():
    text, n = redact_text("personnel (at) example-phil (dot) org")
    assert n == 1 and text == EMAIL_PLACEHOLDER


@pytest.mark.parametrize(
    "phone",
    [
        "+1 212 555 0100",
        "+44 (0)20 7123 4567",
        "+49 30 12345678",
        "(661) 323-7928",
        "(02) 9876 5432",
        "661-323-7928",
        "661.323.7928",
        "661 323 7928",
        "030 1234 5678",
        "0171/123 45 67",
        "Tel. 030-1234567",
        "Phone: 555 010 2030",
        "Fon +49 (0)89 1234-0",
    ],
)
def test_phone_numbers_are_removed(phone):
    text, n = redact_text(f"Questions: {phone} (office hours)")
    assert n >= 1 and PHONE_PLACEHOLDER in text
    assert not any(ch.isdigit() for ch in text), text
    assert contains_contact(phone)


@pytest.mark.parametrize(
    "keep",
    [
        "Quill: Symphony No. 5, II: mm. 1-106",
        "Amberlin: Symphony No. 14, K. 312",
        "Dunmere: Suite No. 1, BWV 2207",
        "Application deadline: 2026-11-15",
        "Deadline 15 November 2026, 17:00",
        "Deadline 01/02/2026 10:00",
        "Bewerbungsschluss 15.11.2026",
        "Reine: Night Fanfare, Op. 30, mm. 1-62, 90-175",
        "Zarkhovin: Symphony No. 5, Op. 38, I: reh. 9-12",
        "Saxophone and 2 trumpets; cello section",
        "Eskholm: Cello Concerto in A, Hob. VIIb:9, mvt. 1 to bar 100",
        "Salary $71,592 per 42-week season",
    ],
)
def test_musical_facts_and_dates_survive(keep):
    text, n = redact_text(keep)
    assert n == 0 and text == keep


def test_redact_value_walks_nested_structures():
    value = {"a": ["x@y.org", {"b": "ok", "c": 3}], "d": "call (555) 010-2030", "e": None}
    out, n = redact_value(value)
    assert n == 2
    assert out == {"a": [EMAIL_PLACEHOLDER, {"b": "ok", "c": 3}], "d": f"call {PHONE_PLACEHOLDER}", "e": None}


def test_empty_text_is_untouched():
    assert redact_text("") == ("", 0)
