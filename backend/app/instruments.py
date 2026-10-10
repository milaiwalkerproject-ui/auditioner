"""The 22 catalogue instruments (same ids as content/schema/catalog.schema.json and
the Swift `Instrument` enum) with what the MusicXML part should say about them."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class InstrumentInfo:
    id: str
    name: str  # part name shown by notation software, sentence case like the app
    sound: str | None  # MusicXML standard instrument sound id
    midi_program: int  # General MIDI program, 1-based
    midi_channel: int = 1


_LIST = [
    InstrumentInfo("violin", "Violin", "strings.violin", 41),
    InstrumentInfo("viola", "Viola", "strings.viola", 42),
    InstrumentInfo("cello", "Cello", "strings.cello", 43),
    InstrumentInfo("double-bass", "Double bass", "strings.contrabass", 44),
    InstrumentInfo("harp", "Harp", "pluck.harp", 47),
    InstrumentInfo("flute", "Flute", "wind.flutes.flute", 74),
    InstrumentInfo("piccolo", "Piccolo", "wind.flutes.flute.piccolo", 73),
    InstrumentInfo("oboe", "Oboe", "wind.reed.oboe", 69),
    InstrumentInfo("english-horn", "English horn", "wind.reed.english-horn", 70),
    InstrumentInfo("clarinet", "Clarinet", "wind.reed.clarinet", 72),
    InstrumentInfo("e-flat-clarinet", "E♭ clarinet", "wind.reed.clarinet.eflat", 72),
    InstrumentInfo("bass-clarinet", "Bass clarinet", "wind.reed.clarinet.bass", 72),
    InstrumentInfo("bassoon", "Bassoon", "wind.reed.bassoon", 71),
    InstrumentInfo("contrabassoon", "Contrabassoon", "wind.reed.contrabassoon", 71),
    InstrumentInfo("horn", "Horn", "brass.french-horn", 61),
    InstrumentInfo("trumpet", "Trumpet", "brass.trumpet", 57),
    InstrumentInfo("trombone", "Trombone", "brass.trombone", 58),
    InstrumentInfo("bass-trombone", "Bass trombone", "brass.trombone.bass", 58),
    InstrumentInfo("tuba", "Tuba", "brass.tuba", 59),
    InstrumentInfo("timpani", "Timpani", "drum.timpani", 48),
    InstrumentInfo("percussion", "Percussion", None, 1, midi_channel=10),
    InstrumentInfo("keyboard", "Piano / celesta", "keyboard.piano", 1),
]

INSTRUMENTS: dict[str, InstrumentInfo] = {info.id: info for info in _LIST}
INSTRUMENT_IDS: list[str] = [info.id for info in _LIST]


def lookup(instrument_id: str) -> InstrumentInfo | None:
    return INSTRUMENTS.get(instrument_id.strip().lower())
