from __future__ import annotations

from crawler.documents import text_document
from crawler.schema import coerce_item, coerce_vacancy
from crawler.verify import verify_dated, verify_item, verify_vacancy

LINES = text_document(
    "\n".join(
        [
            "Example Philharmonic — Section Cello",
            "Application deadline: 15 November 2026",
            "Lindovář: Symphony No. 8, mvt. I, mm. 1–18",
            "Quill: Symphony No. 5, II: mm. 1-106",
            "Reine: Night Fanfare, beginning to 4 before [C]",
            "Sight reading may be required",
        ]
    )
).by_id


def item(**fields):
    base = {"sourceLineIds": ["L0003"], "category": "excerpt", "composer": "Lindovář", "work": "Symphony No. 8",
            "movement": "I", "location": {"type": "measures", "startBar": 1, "endBar": 18}}
    base.update(fields)
    return coerce_item(base)


def test_item_passes_when_cited_lines_carry_composer_work_and_bars():
    verification = verify_item(item(), LINES)
    assert verification.ok and verification.flags == []
    assert verification.cited_line_ids == ["L0003"]


def test_diacritics_do_not_matter():
    assert verify_item(item(composer="Lindovar"), LINES).ok
    assert verify_item(item(composer="Ondrej Lindovár"), LINES).ok


def test_item_is_rejected_when_cited_lines_lack_the_composer():
    verification = verify_item(item(composer="Thornquist"), LINES)
    assert not verification.ok and "composer_not_in_cited_lines" in verification.flags


def test_item_is_rejected_when_cited_lines_lack_the_work():
    verification = verify_item(item(work="Cello Concerto"), LINES)
    assert not verification.ok and "work_not_in_cited_lines" in verification.flags


def test_missing_or_empty_citations_are_rejected():
    assert "no_source_lines" in verify_item(item(sourceLineIds=[]), LINES).flags
    verification = verify_item(item(sourceLineIds=["L0999"]), LINES)
    assert not verification.ok and "line_missing" in verification.flags


def test_bars_must_parse_and_be_printed_in_the_cited_lines():
    bad = verify_item(item(location={"type": "measures", "startBar": 18, "endBar": 1}), LINES)
    assert "bars_invalid" in bad.flags and not bad.ok
    invented = verify_item(item(location={"type": "measures", "startBar": 1, "endBar": 44}), LINES)
    assert "bars_not_in_cited_lines" in invented.flags and not invented.ok
    rehearsal = verify_item(item(sourceLineIds=["L0005"], composer="Reine", work="Night Fanfare", movement="",
                                 location={"type": "rehearsal_mark", "startText": "beginning", "endText": "4 before [C]"}), LINES)
    assert rehearsal.ok
    soft = verify_item(item(location={"type": "unknown", "startBar": 1, "endBar": 18}), LINES)
    assert soft.ok and "bars_without_measures_type" in soft.flags


def test_catalogue_number_must_be_printed_too():
    flagged = verify_item(item(catalogueNumber="Op. 54"), LINES)
    assert "catalogue_number_not_in_cited_lines" in flagged.flags and flagged.ok  # soft flag


def test_dates_survive_only_when_the_cited_lines_carry_them():
    assert verify_dated({"value": "2026-11-15", "sourceLineIds": ["L0002"]}, LINES) == ("2026-11-15", [])
    assert verify_dated({"value": "2026-11-16", "sourceLineIds": ["L0002"]}, LINES) == ("", ["date_not_in_cited_lines"])
    assert verify_dated({"value": "2026-11-15", "sourceLineIds": []}, LINES) == ("", ["date_without_source_lines"])
    assert verify_dated({"value": "", "sourceLineIds": []}, LINES) == ("", [])
    numeric = text_document("Bewerbungsschluss: 15.11.2026").by_id
    assert verify_dated({"value": "2026-11-15", "sourceLineIds": ["L0001"]}, numeric)[0] == "2026-11-15"
    iso = text_document("JobPosting validThrough: 2026-11-15").by_id
    assert verify_dated({"value": "2026-11-15", "sourceLineIds": ["L0001"]}, iso)[0] == "2026-11-15"


def test_verify_vacancy_blanks_unverified_dates_and_flags_gaps():
    vacancy = coerce_vacancy({
        "position": "", "instrument": "other",
        "applicationDeadline": {"value": "2026-12-01", "sourceLineIds": ["L0002"]},
        "auditionDates": [{"value": "2026-11-15", "sourceLineIds": ["L0002"]}, {"value": "2027-01-01", "sourceLineIds": ["L0001"]}],
        "items": [item(), item(composer="Thornquist")],
    })
    cleaned, verifications, flags = verify_vacancy(vacancy, LINES)
    assert cleaned["applicationDeadline"]["value"] == ""
    assert [d["value"] for d in cleaned["auditionDates"]] == ["2026-11-15"]
    assert "deadline:date_not_in_cited_lines" in flags
    assert "auditionDate:date_not_in_cited_lines" in flags
    assert "position_missing" in flags and "instrument_unknown" in flags
    assert [v.ok for v in verifications] == [True, False]
