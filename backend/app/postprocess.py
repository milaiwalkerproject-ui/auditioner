"""Tidy homr's MusicXML for the app, with plain xml.etree.ElementTree.

What happens, in order (see backend/README.md):

1. the part is named after the instrument the player chose;
2. a `<transpose>` is written into the first `<attributes>` when the part is a
   transposing one (double bass -12, clarinet in B♭ -2, …);
3. if the catalogue knows the meter, every `<time>` is replaced with it (homr's own
   guess is never trusted, PLAN.md R2) and the player is told;
4. every bar's length is checked against the time signature (voice 1 only, chords and
   grace notes ignored, `<backup>`/`<forward>` followed) — bars that don't add up get a
   warning, a short first bar is treated as a pickup;
5. if the OCR hints contain a metronome mark ("♩ = 96") and the score has no tempo,
   one is written into bar 1 so playback starts at the printed speed;
6. measures are counted.

Comments (homr writes `<!-- imgpos: x, y -->` into each note; the correction editor in
M2 will want them) and the DOCTYPE, if any, are preserved. Everything else is left
exactly as homr wrote it.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from fractions import Fraction

from .instruments import InstrumentInfo

XML_DECLARATION = '<?xml version="1.0" encoding="UTF-8"?>\n'
_DOCTYPE_RE = re.compile(rb"<!DOCTYPE[^\[>]*(\[[^\]]*\])?[^>]*>", re.DOTALL)

# Order of children inside <attributes> (MusicXML 4.0), used to insert new elements
# in a sensible place even when the engine's own order is loose.
_ATTRIBUTES_ORDER = [
    "footnote", "level", "divisions", "key", "time", "staves", "part-symbol",
    "instruments", "clef", "staff-details", "transpose", "for-part", "directive",
    "measure-style",
]
# Order of children inside <score-part>.
_SCORE_PART_ORDER = [
    "identification", "part-link", "part-name", "part-name-display", "part-abbreviation",
    "part-abbreviation-display", "group", "score-instrument", "player", "midi-device",
    "midi-instrument",
]

METER_RE = re.compile(r"^\s*(\d{1,2})\s*/\s*(1|2|4|8|16|32|64)\s*$")

# "♩ = 96", "♩. = 60", "q = 96", "e=120", "= 96", "M.M. ♩ = ca. 96"
_TEMPO_RE = re.compile(
    r"(?:(?P<unit>[♩♪\U0001d15e\U0001d15f\U0001d160]|\b[qeh])(?P<dot>\s*\.)?\s*)?"
    r"=\s*(?:ca\.?|c\.|circa|about)?\s*(?P<bpm>\d{2,3})(?!\d)",
    re.IGNORECASE,
)
_UNIT_QUARTERS = {
    "♩": Fraction(1),      # ♩ quarter
    "\U0001d15f": Fraction(1),  # 𝅘𝅥 quarter
    "q": Fraction(1),
    "♪": Fraction(1, 2),   # ♪ eighth
    "\U0001d160": Fraction(1, 2),  # 𝅘𝅥𝅮 eighth
    "e": Fraction(1, 2),
    "\U0001d15e": Fraction(2),  # 𝅗𝅥 half
    "h": Fraction(2),
}
_UNIT_NAMES = {Fraction(1): "quarter", Fraction(1, 2): "eighth", Fraction(2): "half"}
TEMPO_MIN, TEMPO_MAX = 40, 240


class MalformedMusicXML(Exception):
    """The engine's output could not be parsed."""


@dataclass
class TempoHint:
    bpm: int  # as printed
    unit_quarters: Fraction  # length of the printed beat unit in quarter notes
    dotted: bool = False

    @property
    def quarter_bpm(self) -> Fraction:
        unit = self.unit_quarters * (Fraction(3, 2) if self.dotted else 1)
        return Fraction(self.bpm) * unit


@dataclass
class ProcessedScore:
    musicxml: str
    warnings: list[str] = field(default_factory=list)
    measures: int | None = None


# --------------------------------------------------------------------------- parsing


def parse(xml_bytes: bytes) -> tuple[ET.Element, bytes | None]:
    """Parse MusicXML bytes, keeping comments. Returns (root, doctype or None)."""
    match = _DOCTYPE_RE.search(xml_bytes[:4096])
    doctype = match.group(0) if match else None
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        root = ET.fromstring(xml_bytes, parser=parser)
    except (ET.ParseError, IndexError, TypeError):
        try:
            root = ET.fromstring(xml_bytes)
        except ET.ParseError as exc:
            raise MalformedMusicXML(str(exc)) from exc
    if root.tag != "score-partwise":
        raise MalformedMusicXML(f"expected score-partwise, got {root.tag}")
    return root, doctype


def serialise(root: ET.Element, doctype: bytes | None = None) -> str:
    body = ET.tostring(root, encoding="unicode")
    head = XML_DECLARATION
    if doctype:
        head += doctype.decode("utf-8", "replace") + "\n"
    return head + body


# --------------------------------------------------------------------------- helpers


def _ordered_insert(parent: ET.Element, new: ET.Element, order: list[str]) -> None:
    """Insert `new` after the last child that should precede it according to `order`."""
    try:
        rank = order.index(new.tag)
    except ValueError:
        parent.append(new)
        return
    index = 0
    for i, child in enumerate(list(parent)):
        if child.tag in order and order.index(child.tag) <= rank:
            index = i + 1
    parent.insert(index, new)


def _parts(root: ET.Element) -> list[ET.Element]:
    return root.findall("part")


def _first_attributes(part: ET.Element) -> ET.Element | None:
    for measure in part.findall("measure"):
        attributes = measure.find("attributes")
        if attributes is not None:
            return attributes
        if measure.find("note") is not None:
            break
    return None


def _ensure_first_attributes(part: ET.Element) -> ET.Element | None:
    attributes = _first_attributes(part)
    if attributes is not None:
        return attributes
    measures = part.findall("measure")
    if not measures:
        return None
    attributes = ET.Element("attributes")
    measures[0].insert(0, attributes)
    return attributes


def _text_int(element: ET.Element | None, path: str) -> int | None:
    if element is None:
        return None
    text = element.findtext(path)
    if text is None:
        return None
    try:
        return int(text.strip())
    except ValueError:
        return None


def _fmt(value: Fraction) -> str:
    return f"{float(value):.2f}".rstrip("0").rstrip(".")


# ----------------------------------------------------------------- 1. part name


def set_part_names(root: ET.Element, instrument: InstrumentInfo) -> None:
    part_list = root.find("part-list")
    parts = _parts(root)
    if part_list is None:
        part_list = ET.Element("part-list")
        first_part = parts[0] if parts else None
        index = list(root).index(first_part) if first_part is not None else len(root)
        root.insert(index, part_list)
    score_parts = part_list.findall("score-part")
    if not score_parts:
        for part in parts:
            score_part = ET.SubElement(part_list, "score-part", id=part.get("id", "P1"))
            score_parts.append(score_part)
    for score_part in score_parts:
        part_id = score_part.get("id", "P1")
        name = score_part.find("part-name")
        if name is None:
            name = ET.Element("part-name")
            _ordered_insert(score_part, name, _SCORE_PART_ORDER)
        name.text = instrument.name
        for tag in ("score-instrument", "midi-instrument"):
            for old in score_part.findall(tag):
                score_part.remove(old)
        instrument_id = f"{part_id}-I1"
        score_instrument = ET.Element("score-instrument", id=instrument_id)
        ET.SubElement(score_instrument, "instrument-name").text = instrument.name
        if instrument.sound:
            ET.SubElement(score_instrument, "instrument-sound").text = instrument.sound
        _ordered_insert(score_part, score_instrument, _SCORE_PART_ORDER)
        midi = ET.Element("midi-instrument", id=instrument_id)
        ET.SubElement(midi, "midi-channel").text = str(instrument.midi_channel)
        ET.SubElement(midi, "midi-program").text = str(instrument.midi_program)
        _ordered_insert(score_part, midi, _SCORE_PART_ORDER)


# --------------------------------------------------------------- 2. transposition


def split_transposition(semitones: int) -> tuple[int, int]:
    """(chromatic, octave-change) for a signed number of semitones.

    -12 → (0, -1); -14 → (-2, -1); +9 → (9, 0); -2 → (-2, 0).
    """
    sign = -1 if semitones < 0 else 1
    magnitude = abs(semitones)
    octaves, chromatic = divmod(magnitude, 12)
    return sign * chromatic, sign * octaves


def set_transposition(root: ET.Element, semitones: int) -> None:
    if semitones == 0:
        return
    chromatic, octave_change = split_transposition(semitones)
    for part in _parts(root):
        attributes = _ensure_first_attributes(part)
        if attributes is None:
            continue
        for old in attributes.findall("transpose"):
            attributes.remove(old)
        transpose = ET.Element("transpose")
        ET.SubElement(transpose, "chromatic").text = str(chromatic)
        if octave_change:
            ET.SubElement(transpose, "octave-change").text = str(octave_change)
        _ordered_insert(attributes, transpose, _ATTRIBUTES_ORDER)


# ------------------------------------------------------------------------ 3. meter


def parse_meter(meter: str) -> tuple[int, int] | None:
    match = METER_RE.match(meter or "")
    if not match:
        return None
    beats, beat_type = int(match.group(1)), int(match.group(2))
    if beats < 1:
        return None
    return beats, beat_type


def set_meter(root: ET.Element, beats: int, beat_type: int) -> str:
    """Replace every <time> with beats/beat-type (adding one if the score has none)."""
    times = list(root.iter("time"))
    if not times:
        for part in _parts(root):
            attributes = _ensure_first_attributes(part)
            if attributes is None:
                continue
            time = ET.Element("time")
            _ordered_insert(attributes, time, _ATTRIBUTES_ORDER)
            times.append(time)
    for time in times:
        for child in list(time):
            time.remove(child)
        time.attrib.pop("symbol", None)
        ET.SubElement(time, "beats").text = str(beats)
        ET.SubElement(time, "beat-type").text = str(beat_type)
    return f"Meter set to {beats}/{beat_type} from the catalogue"


# ------------------------------------------------------------- 4. bar lengths


def _read_time(time: ET.Element) -> tuple[int, int] | None:
    """(beats, beat-type) for a <time>, summing compound signatures; None if unknown."""
    if time.find("senza-misura") is not None:
        return None
    beats_list = time.findall("beats")
    types_list = time.findall("beat-type")
    if not beats_list or not types_list:
        return None
    total = Fraction(0)
    for beats_el, type_el in zip(beats_list, types_list):
        try:
            beat_type = int((type_el.text or "").strip())
            beats = sum(int(b) for b in re.split(r"\s*\+\s*", (beats_el.text or "").strip()) if b)
        except ValueError:
            return None
        if beat_type <= 0 or beats <= 0:
            return None
        total += Fraction(beats, beat_type)
    # express as beats over the first beat-type for the message
    first_type = int((types_list[0].text or "4").strip())
    beats_in_first = total * first_type
    if beats_in_first.denominator != 1:
        return None
    return int(beats_in_first), first_type


def _voice_one(element: ET.Element) -> bool:
    voice = element.findtext("voice")
    return voice is None or voice.strip() in ("", "1")


def measure_length(measure: ET.Element) -> tuple[Fraction, bool, bool]:
    """(length in divisions, has any counted note, is a whole-measure rest) for voice 1."""
    position = Fraction(0)
    end = Fraction(0)
    counted = False
    whole_rest = False
    for element in measure:
        if element.tag == "note":
            if element.find("grace") is not None or element.find("chord") is not None:
                continue
            if not _voice_one(element):
                continue
            rest = element.find("rest")
            if rest is not None and rest.get("measure") == "yes":
                whole_rest = True
            duration = _text_int(element, "duration")
            if duration is None:
                continue
            position += duration
            end = max(end, position)
            counted = True
        elif element.tag == "backup":
            duration = _text_int(element, "duration") or 0
            position = max(Fraction(0), position - duration)
        elif element.tag == "forward":
            if not _voice_one(element):
                continue
            duration = _text_int(element, "duration") or 0
            position += duration
            end = max(end, position)
    return end, counted, whole_rest


def check_bar_lengths(root: ET.Element) -> list[str]:
    warnings: list[str] = []
    seen: set[str] = set()
    for part in _parts(root):
        divisions: int | None = None
        time_sig: tuple[int, int] | None = None
        for index, measure in enumerate(part.findall("measure")):
            for attributes in measure.findall("attributes"):
                new_divisions = _text_int(attributes, "divisions")
                if new_divisions:
                    divisions = new_divisions
                for time in attributes.findall("time"):
                    time_sig = _read_time(time)
            if not divisions or time_sig is None:
                continue
            beats, beat_type = time_sig
            length, counted, whole_rest = measure_length(measure)
            if not counted or whole_rest:
                continue
            beat_length = Fraction(divisions * 4, beat_type)
            expected = beat_length * beats
            if length == expected:
                continue
            if index == 0 and length < expected:
                continue  # pickup bar
            label = (measure.get("number") or "").strip() or str(index + 1)
            if label in seen:
                continue
            seen.add(label)
            actual_beats = length / beat_length
            warnings.append(
                f"Bar {label} doesn't add up ({_fmt(actual_beats)} beats in a "
                f"{beats}/{beat_type} bar) — check it"
            )
    return warnings


# ------------------------------------------------------------------- 5. tempo


def tempo_from_hints(hints: list[str]) -> TempoHint | None:
    for line in hints:
        if not isinstance(line, str):
            continue
        for match in _TEMPO_RE.finditer(line):
            bpm = int(match.group("bpm"))
            if not TEMPO_MIN <= bpm <= TEMPO_MAX:
                continue
            unit = (match.group("unit") or "").lower()
            return TempoHint(
                bpm=bpm,
                unit_quarters=_UNIT_QUARTERS.get(unit, Fraction(1)),
                dotted=bool(match.group("dot")),
            )
    return None


def has_tempo(root: ET.Element) -> bool:
    for sound in root.iter("sound"):
        if sound.get("tempo"):
            return True
    for metronome in root.iter("metronome"):
        if metronome.find("per-minute") is not None:
            return True
    return False


def add_tempo(root: ET.Element, hint: TempoHint) -> bool:
    """Write a metronome direction into bar 1 of the first part. Returns True if added."""
    parts = _parts(root)
    if not parts:
        return False
    measures = parts[0].findall("measure")
    if not measures:
        return False
    first = measures[0]
    direction = ET.Element("direction", placement="above")
    direction_type = ET.SubElement(direction, "direction-type")
    metronome = ET.SubElement(direction_type, "metronome")
    ET.SubElement(metronome, "beat-unit").text = _UNIT_NAMES.get(hint.unit_quarters, "quarter")
    if hint.dotted:
        ET.SubElement(metronome, "beat-unit-dot")
    ET.SubElement(metronome, "per-minute").text = str(hint.bpm)
    ET.SubElement(direction, "sound", tempo=_fmt(hint.quarter_bpm))
    index = len(first)
    for i, child in enumerate(list(first)):
        if child.tag in ("note", "backup", "forward", "direction", "harmony", "figured-bass", "sound"):
            index = i
            break
    first.insert(index, direction)
    return True


# ------------------------------------------------------------------ 6. measures


def count_measures(root: ET.Element) -> int | None:
    parts = _parts(root)
    if not parts:
        return None
    return max(len(part.findall("measure")) for part in parts)


# ------------------------------------------------------------------- pipeline


def postprocess(
    xml_bytes: bytes,
    *,
    instrument: InstrumentInfo,
    transposition: int = 0,
    meter: str | None = None,
    hints: list[str] | None = None,
) -> ProcessedScore:
    root, doctype = parse(xml_bytes)
    warnings: list[str] = []

    set_part_names(root, instrument)
    set_transposition(root, transposition)

    if meter:
        parsed = parse_meter(meter)
        if parsed is not None:
            warnings.append(set_meter(root, *parsed))

    warnings.extend(check_bar_lengths(root))

    hint = tempo_from_hints(hints or [])
    if hint is not None and not has_tempo(root):
        add_tempo(root, hint)

    return ProcessedScore(
        musicxml=serialise(root, doctype),
        warnings=warnings,
        measures=count_measures(root),
    )
