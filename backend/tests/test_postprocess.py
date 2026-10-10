"""Unit tests for the MusicXML post-processing."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from fractions import Fraction

import pytest

from app.instruments import INSTRUMENTS
from app.postprocess import (
    MalformedMusicXML,
    TempoHint,
    add_tempo,
    check_bar_lengths,
    count_measures,
    has_tempo,
    parse,
    parse_meter,
    postprocess,
    serialise,
    set_meter,
    set_part_names,
    set_transposition,
    split_transposition,
    tempo_from_hints,
)

CELLO = INSTRUMENTS["cello"]
BASS = INSTRUMENTS["double-bass"]


def note(step: str, duration: int, voice: int = 1, extra: str = "") -> str:
    return (
        f"<note>{extra}<pitch><step>{step}</step><octave>3</octave></pitch>"
        f"<duration>{duration}</duration><voice>{voice}</voice></note>"
    )


def rest(duration: int, whole: bool = False) -> str:
    rest_tag = '<rest measure="yes"/>' if whole else "<rest/>"
    return f"<note>{rest_tag}<duration>{duration}</duration><voice>1</voice></note>"


def score(measures: list[str], divisions: int = 4, beats: int = 4, beat_type: int = 4, time: bool = True) -> bytes:
    time_xml = f"<time><beats>{beats}</beats><beat-type>{beat_type}</beat-type></time>" if time else ""
    attributes = f"<attributes><divisions>{divisions}</divisions><key><fifths>0</fifths></key>{time_xml}<clef><sign>F</sign><line>4</line></clef></attributes>"
    body = "".join(
        f'<measure number="{i + 1}">{attributes if i == 0 else ""}{m}</measure>' for i, m in enumerate(measures)
    )
    return (
        "<?xml version='1.0' encoding='utf-8'?>"
        '<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Staff</part-name></score-part></part-list>'
        f'<part id="P1">{body}</part></score-partwise>'
    ).encode()


# ------------------------------------------------------------------ parsing


def test_parse_keeps_comments_and_doctype():
    xml = (
        b'<?xml version="1.0" encoding="UTF-8"?>\n'
        b'<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">\n'
        b'<score-partwise version="4.0"><part-list/><part id="P1"><measure number="1">'
        b"<note><duration>4</duration><!-- imgpos: 1, 2 --></note></measure></part></score-partwise>"
    )
    root, doctype = parse(xml)
    out = serialise(root, doctype)
    assert out.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE score-partwise')
    assert "<!-- imgpos: 1, 2 -->" in out


def test_parse_rejects_garbage():
    with pytest.raises(MalformedMusicXML):
        parse(b"this is not xml")
    with pytest.raises(MalformedMusicXML):
        parse(b"<html/>")


# ---------------------------------------------------------------- part name


def test_set_part_names_replaces_homr_defaults():
    root, _ = parse(score([note("C", 16)]))
    set_part_names(root, CELLO)
    score_part = root.find("part-list/score-part")
    assert score_part.findtext("part-name") == "Cello"
    assert score_part.find("score-instrument").get("id") == "P1-I1"
    assert score_part.findtext("score-instrument/instrument-name") == "Cello"
    assert score_part.findtext("score-instrument/instrument-sound") == "strings.cello"
    assert score_part.findtext("midi-instrument/midi-program") == "43"
    tags = [child.tag for child in score_part]
    assert tags == ["part-name", "score-instrument", "midi-instrument"]


def test_set_part_names_creates_missing_part_list():
    root = ET.fromstring('<score-partwise><part id="P1"><measure number="1"/></part></score-partwise>')
    set_part_names(root, BASS)
    assert [c.tag for c in root] == ["part-list", "part"]
    assert root.findtext("part-list/score-part/part-name") == "Double bass"


# ------------------------------------------------------------ transposition


@pytest.mark.parametrize(
    "semitones,expected",
    [(0, (0, 0)), (-12, (0, -1)), (-14, (-2, -1)), (-2, (-2, 0)), (9, (9, 0)), (12, (0, 1)), (-24, (0, -2)), (-19, (-7, -1))],
)
def test_split_transposition(semitones, expected):
    assert split_transposition(semitones) == expected


def test_no_transpose_for_cello():
    root, _ = parse(score([note("C", 16)]))
    set_transposition(root, 0)
    assert root.find(".//transpose") is None


def test_transpose_double_bass():
    root, _ = parse(score([note("C", 16)]))
    set_transposition(root, -12)
    attributes = root.find("part/measure/attributes")
    tags = [child.tag for child in attributes]
    assert tags == ["divisions", "key", "time", "clef", "transpose"]
    transpose = attributes.find("transpose")
    assert transpose.findtext("chromatic") == "0"
    assert transpose.findtext("octave-change") == "-1"


def test_transpose_replaces_existing():
    root, _ = parse(score([note("C", 16)]))
    root.find("part/measure/attributes").append(ET.fromstring("<transpose><chromatic>5</chromatic></transpose>"))
    set_transposition(root, -2)
    transposes = root.findall(".//transpose")
    assert len(transposes) == 1
    assert transposes[0].findtext("chromatic") == "-2"


def test_transpose_homr_style_attributes_order():
    """homr puts divisions/time in one <attributes> and clef/key in a second one."""
    xml = (
        b'<score-partwise version="4.0"><part-list/><part id="P1"><measure number="1">'
        b"<attributes><divisions>24</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
        b"<attributes><clef><sign>F</sign><line>4</line></clef><key><fifths>0</fifths></key></attributes>"
        b"<note><duration>96</duration></note></measure></part></score-partwise>"
    )
    root, _ = parse(xml)
    set_transposition(root, -12)
    first = root.find("part/measure/attributes")
    assert [c.tag for c in first] == ["divisions", "time", "transpose"]


# -------------------------------------------------------------------- meter


@pytest.mark.parametrize("text,expected", [("3/4", (3, 4)), ("6/8", (6, 8)), (" 12/16 ", (12, 16)), ("2/2", (2, 2))])
def test_parse_meter_ok(text, expected):
    assert parse_meter(text) == expected


@pytest.mark.parametrize("text", ["", "waltz", "3/5", "0/4", "3-4", "4/4/4", "C"])
def test_parse_meter_bad(text):
    assert parse_meter(text) is None


def test_set_meter_replaces_all_time_elements():
    root, _ = parse(score([note("C", 16), note("D", 16)]))
    root.find("part/measure/attributes/time").set("symbol", "common")
    warning = set_meter(root, 3, 4)
    assert warning == "Meter set to 3/4 from the catalogue"
    times = root.findall(".//time")
    assert len(times) == 1
    assert [c.tag for c in times[0]] == ["beats", "beat-type"]
    assert times[0].findtext("beats") == "3"
    assert times[0].get("symbol") is None


def test_set_meter_adds_time_when_missing():
    root, _ = parse(score([note("C", 12)], time=False))
    set_meter(root, 3, 4)
    attributes = root.find("part/measure/attributes")
    assert [c.tag for c in attributes] == ["divisions", "key", "time", "clef"]
    assert check_bar_lengths(root) == []


# -------------------------------------------------------------- bar lengths


def test_bar_lengths_full_bars_ok():
    root, _ = parse(score([note("C", 16), note("D", 8) + note("E", 8)]))
    assert check_bar_lengths(root) == []


def test_bar_lengths_pickup_allowed():
    root, _ = parse(score([note("C", 4), note("D", 16)]))
    assert check_bar_lengths(root) == []


def test_bar_lengths_long_first_bar_warned():
    root, _ = parse(score([note("C", 18), note("D", 16)]))
    assert check_bar_lengths(root) == ["Bar 1 doesn't add up (4.5 beats in a 4/4 bar) — check it"]


def test_bar_lengths_short_bar_warned():
    root, _ = parse(score([note("C", 16), note("D", 14), note("E", 16)]))
    assert check_bar_lengths(root) == ["Bar 2 doesn't add up (3.5 beats in a 4/4 bar) — check it"]


def test_bar_lengths_uses_measure_number_attribute():
    root, _ = parse(score([note("C", 16), note("D", 12)]))
    root.findall("part/measure")[1].set("number", "17")
    assert check_bar_lengths(root) == ["Bar 17 doesn't add up (3 beats in a 4/4 bar) — check it"]


def test_bar_lengths_ignores_chord_and_grace_notes():
    bar = note("C", 8) + note("E", 8, extra="<chord/>") + note("F", 0, extra="<grace/>") + note("G", 8)
    root, _ = parse(score([note("C", 16), bar]))
    assert check_bar_lengths(root) == []


def test_bar_lengths_backup_forward_and_voices():
    bar = note("C", 16) + "<backup><duration>16</duration></backup>" + note("E", 8, voice=2) + note("G", 8, voice=2)
    short_v1_full_v2 = note("C", 8) + "<backup><duration>8</duration></backup>" + note("E", 16, voice=2)
    forward_bar = note("C", 8) + "<forward><duration>8</duration></forward>"
    root, _ = parse(score([note("C", 16), bar, short_v1_full_v2, forward_bar]))
    assert check_bar_lengths(root) == ["Bar 3 doesn't add up (2 beats in a 4/4 bar) — check it"]


def test_bar_lengths_whole_measure_rest_ok():
    root, _ = parse(score([note("C", 16), rest(16, whole=True), rest(8, whole=True)]))
    assert check_bar_lengths(root) == []


def test_bar_lengths_compound_meter():
    root, _ = parse(score([note("C", 12), note("D", 10)], divisions=4, beats=6, beat_type=8))
    assert check_bar_lengths(root) == ["Bar 2 doesn't add up (5 beats in a 6/8 bar) — check it"]


def test_bar_lengths_time_change_mid_score():
    change = "<attributes><time><beats>3</beats><beat-type>4</beat-type></time></attributes>"
    root, _ = parse(score([note("C", 16), change + note("D", 12), note("E", 16)]))
    assert check_bar_lengths(root) == ["Bar 3 doesn't add up (4 beats in a 3/4 bar) — check it"]


def test_bar_lengths_no_time_signature_skips():
    root, _ = parse(score([note("C", 7), note("D", 3)], time=False))
    assert check_bar_lengths(root) == []


def test_bar_lengths_empty_measure_skipped():
    root, _ = parse(score([note("C", 16), "", note("D", 16)]))
    assert check_bar_lengths(root) == []


# --------------------------------------------------------------------- tempo


@pytest.mark.parametrize(
    "line,bpm,quarter_bpm",
    [
        ("♩ = 96", 96, 96),
        ("♩=96", 96, 96),
        ("q = 96", 96, 96),
        ("= 96", 96, 96),
        ("M.M. ♩ = ca. 120", 120, 120),
        ("♪ = 120", 120, 60),
        ("e = 120", 120, 60),
        ("h = 60", 60, 120),
        ("♩. = 60", 60, 90),
        ("Allegro (♩ = 132)", 132, 132),
        ("\U0001d15f = 72", 72, 72),
    ],
)
def test_tempo_from_hints(line, bpm, quarter_bpm):
    hint = tempo_from_hints(["Violoncello", line])
    assert hint is not None
    assert hint.bpm == bpm
    assert hint.quarter_bpm == Fraction(quarter_bpm)


@pytest.mark.parametrize("line", ["♩ = 39", "♩ = 241", "Op. 67 = 1808", "no mark here", "= 9", "♩ = 1000"])
def test_tempo_from_hints_rejects(line):
    assert tempo_from_hints([line]) is None


def test_tempo_hint_ignores_non_strings():
    assert tempo_from_hints([None, 42, "♩ = 80"]).bpm == 80  # type: ignore[list-item]


def test_add_tempo_into_bar_one():
    root, _ = parse(score([note("C", 16), note("D", 16)]))
    assert not has_tempo(root)
    assert add_tempo(root, TempoHint(bpm=96, unit_quarters=Fraction(1)))
    first = root.find("part/measure")
    assert [c.tag for c in first] == ["attributes", "direction", "note"]
    direction = first.find("direction")
    assert direction.find("sound").get("tempo") == "96"
    assert direction.findtext("direction-type/metronome/beat-unit") == "quarter"
    assert direction.findtext("direction-type/metronome/per-minute") == "96"
    assert has_tempo(root)


def test_add_tempo_dotted_eighth_unit():
    root, _ = parse(score([note("C", 16)]))
    add_tempo(root, TempoHint(bpm=100, unit_quarters=Fraction(1, 2), dotted=True))
    direction = root.find("part/measure/direction")
    assert direction.find("sound").get("tempo") == "75"
    assert direction.find("direction-type/metronome/beat-unit-dot") is not None


def test_existing_tempo_is_kept():
    root, _ = parse(score(['<direction><direction-type><words>Fast</words></direction-type><sound tempo="140"/></direction>' + note("C", 16)]))
    out = postprocess(serialise(root).encode(), instrument=CELLO, hints=["♩ = 60"])
    sounds = ET.fromstring(out.musicxml).findall(".//sound")
    assert [s.get("tempo") for s in sounds] == ["140"]


# ------------------------------------------------------------------ pipeline


def test_count_measures():
    root, _ = parse(score([note("C", 16)] * 7))
    assert count_measures(root) == 7
    assert count_measures(ET.fromstring("<score-partwise/>")) is None


def test_postprocess_end_to_end():
    xml = score([note("C", 4), note("D", 16), note("E", 10)])
    out = postprocess(xml, instrument=BASS, transposition=-12, meter="3/4", hints=["Largo", "♩ = 52"])
    assert out.measures == 3
    assert out.warnings == [
        "Meter set to 3/4 from the catalogue",
        "Bar 2 doesn't add up (4 beats in a 3/4 bar) — check it",
        "Bar 3 doesn't add up (2.5 beats in a 3/4 bar) — check it",
    ]
    root = ET.fromstring(out.musicxml)
    assert root.findtext("part-list/score-part/part-name") == "Double bass"
    assert root.findtext("part/measure/attributes/transpose/octave-change") == "-1"
    assert root.find("part/measure/direction/sound").get("tempo") == "52"
    assert out.musicxml.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise')
