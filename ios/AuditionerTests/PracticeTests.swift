import XCTest
@testable import Auditioner

final class PracticeTests: XCTestCase {

    // MARK: Fixtures

    private func demoXML() throws -> String {
        let doc = ScoreDocument.bundled(named: "demo-d-major-scale.musicxml", title: "Demo", origin: .demo,
                                        instrument: .cello, bundle: Bundle(for: CatalogStore.self))
        return try XCTUnwrap(doc).musicXML
    }

    /// Grace note (skipped), rest, tie across the barline, chord, second voice (ignored), dotted + tuplet durations.
    private let richXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <work><work-title>Test</work-title></work>
      <part-list><score-part id="P1"><part-name>Cello</part-name></score-part><score-part id="P2"><part-name>Other</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>2</divisions>
            <key><fifths>-1</fifths></key>
            <time><beats>3</beats><beat-type>4</beat-type></time>
            <clef><sign>F</sign><line>4</line></clef>
            <transpose><chromatic>-2</chromatic><octave-change>-1</octave-change></transpose>
          </attributes>
          <direction placement="above">
            <direction-type><metronome><beat-unit>half</beat-unit><beat-unit-dot/><per-minute>40</per-minute></metronome></direction-type>
          </direction>
          <note><grace/><pitch><step>C</step><octave>3</octave></pitch><type>eighth</type></note>
          <note><pitch><step>D</step><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type></note>
          <note><rest/><duration>2</duration><voice>1</voice><type>quarter</type></note>
          <note><pitch><step>F</step><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type><tie type="start"/><notations><tied type="start"/></notations></note>
          <note><chord/><pitch><step>A</step><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type></note>
          <backup><duration>6</duration></backup>
          <note><pitch><step>C</step><octave>2</octave></pitch><duration>6</duration><voice>2</voice><type>half</type><dot/></note>
        </measure>
        <measure number="2">
          <note><pitch><step>F</step><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type><tie type="stop"/><notations><tied type="stop"/></notations></note>
          <note><pitch><step>G</step><octave>3</octave></pitch><duration>1</duration><voice>1</voice><type>eighth</type></note>
          <note><pitch><step>A</step><octave>3</octave></pitch><duration>1</duration><voice>1</voice><type>eighth</type></note>
          <note><pitch><step>B</step><alter>-1</alter><octave>3</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type></note>
          <sound tempo="90"/>
        </measure>
      </part>
      <part id="P2">
        <measure number="1">
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>6</duration><voice>1</voice><type>half</type><dot/></note>
        </measure>
      </part>
    </score-partwise>
    """

    // MARK: Parser

    func testDemoScaleParses() throws {
        let score = try MusicXMLParser.parse(try demoXML())
        XCTAssertEqual(score.measures.count, 4)
        XCTAssertEqual(score.notes.count, 15)
        XCTAssertEqual(score.keyFifths, 2)
        XCTAssertEqual(score.divisions, 1)
        XCTAssertEqual(score.tempoChanges.count, 1)
        XCTAssertEqual(score.tempoChanges.first?.bpm, 80)
        XCTAssertEqual(score.tempoChanges.first?.beat, 0)
        XCTAssertEqual(score.timeSignatures.first?.beats, 4)
        XCTAssertEqual(score.timeSignatures.first?.beatType, 4)
        XCTAssertEqual(score.clefs.first?.sign, "F")
        XCTAssertEqual(score.clefs.first?.line, 4)
        XCTAssertEqual(score.transposeChromatic, 0)
        XCTAssertEqual(score.workTitle, "Demo: D major scale")
        XCTAssertEqual(score.partName, "Cello")

        let first = try XCTUnwrap(score.notes.first)
        XCTAssertEqual(first.midi, 50) // D3
        XCTAssertEqual(first.startBeat, 0)
        XCTAssertEqual(first.durationBeats, 1)

        let last = try XCTUnwrap(score.notes.last)
        XCTAssertEqual(last.midi, 50)
        XCTAssertEqual(last.startBeat, 14)
        XCTAssertEqual(last.durationBeats, 2)

        XCTAssertEqual(score.measures.map { $0.startBeat }, [0, 4, 8, 12])
        XCTAssertEqual(score.measures.map { $0.lengthBeats }, [4, 4, 4, 4])
        XCTAssertEqual(score.measures.map { $0.number }, ["1", "2", "3", "4"])
        XCTAssertEqual(score.totalBeats, 16)
        // F#3 in measure 1
        XCTAssertEqual(score.measures[0].notes[2].midi, 54)
    }

    func testFirstPartVoiceOneGraceChordTieAndBackup() throws {
        let score = try MusicXMLParser.parse(richXML)
        XCTAssertEqual(score.measures.count, 2, "only the first part is read")
        XCTAssertEqual(score.keyFifths, -1)
        XCTAssertEqual(score.transposeChromatic, -2)
        XCTAssertEqual(score.transposeOctaveChange, -1)
        XCTAssertEqual(score.transposeSemitones, -14)
        XCTAssertEqual(score.timeSignatures.first?.barLengthBeats, 3)

        // dotted half = 40 → quarter = 120; then <sound tempo="90"/> at the end of bar 2
        XCTAssertEqual(score.tempoChanges.count, 2)
        XCTAssertEqual(try XCTUnwrap(score.tempoChanges.first).bpm, 120, accuracy: 1e-9)
        XCTAssertEqual(score.tempoChanges[1].bpm, 90)
        XCTAssertEqual(score.tempoChanges[1].beat, 6)

        let m1 = score.measures[0]
        XCTAssertEqual(m1.lengthBeats, 3, "voice 2 after <backup> fills the bar but is not kept")
        XCTAssertEqual(m1.notes.count, 4, "grace skipped, voice 2 skipped: D, rest, F, A(chord)")
        XCTAssertEqual(m1.notes[0].midi, 50)
        XCTAssertEqual(m1.notes[0].startBeat, 0)
        XCTAssertTrue(m1.notes[1].isRest)
        XCTAssertEqual(m1.notes[1].startBeat, 1)
        XCTAssertEqual(m1.notes[2].midi, 53)
        XCTAssertEqual(m1.notes[2].startBeat, 2)
        XCTAssertTrue(m1.notes[2].tieStart)
        XCTAssertFalse(m1.notes[2].tieStop)
        XCTAssertTrue(m1.notes[3].isChordMember)
        XCTAssertEqual(m1.notes[3].midi, 57)
        XCTAssertEqual(m1.notes[3].startBeat, 2)

        let m2 = score.measures[1]
        XCTAssertEqual(m2.startBeat, 3)
        XCTAssertEqual(m2.notes.count, 4)
        XCTAssertTrue(m2.notes[0].tieStop)
        XCTAssertEqual(m2.notes[1].durationBeats, 0.5)
        XCTAssertEqual(m2.notes[3].midi, 58) // B♭3
        XCTAssertEqual(score.totalBeats, 6)
    }

    func testDurationFallsBackToTypeDotsAndTuplet() throws {
        let xml = """
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        <note><pitch><step>C</step><octave>4</octave></pitch><type>quarter</type><dot/></note>
        <note><pitch><step>D</step><octave>4</octave></pitch><type>eighth</type><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification></note>
        </measure></part></score-partwise>
        """
        let score = try MusicXMLParser.parse(xml)
        XCTAssertEqual(score.notes.count, 2)
        XCTAssertEqual(score.notes[0].durationBeats, 1.5, accuracy: 1e-9)
        XCTAssertEqual(score.notes[1].durationBeats, 0.5 * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(score.notes[0].midi, 60)
    }

    func testTimewiseIsRejected() {
        let xml = """
        <score-timewise version="4.0"><part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
        <measure number="1"><part id="P1"><note><rest/><duration>4</duration></note></part></measure></score-timewise>
        """
        XCTAssertThrowsError(try MusicXMLParser.parse(xml)) { error in
            XCTAssertEqual(error as? MusicXMLParseError, MusicXMLParseError.notPartwise)
        }
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try MusicXMLParser.parse("<score-partwise><part><measure>"))
        XCTAssertThrowsError(try MusicXMLParser.parse("not xml at all"))
    }

    func testPitchMath() {
        XCTAssertEqual(PitchMath.midi(step: "A", alter: 0, octave: 4), 69)
        XCTAssertEqual(PitchMath.midi(step: "C", alter: 0, octave: 4), 60)
        XCTAssertEqual(PitchMath.midi(step: "B", alter: -1, octave: 3), 58)
        XCTAssertEqual(PitchMath.midi(step: "F", alter: 1, octave: 3), 54)
        XCTAssertNil(PitchMath.midi(step: "H", alter: 0, octave: 3))
        XCTAssertEqual(PitchMath.dotFactor(dots: 0), 1)
        XCTAssertEqual(PitchMath.dotFactor(dots: 1), 1.5)
        XCTAssertEqual(PitchMath.dotFactor(dots: 2), 1.75)
        XCTAssertEqual(PitchMath.quarters(forNoteType: "half"), 2)
        XCTAssertEqual(PitchMath.quarters(forNoteType: "16th"), 0.25)
    }

    // MARK: Timeline

    func testTimelineFromDemo() throws {
        let score = try MusicXMLParser.parse(try demoXML())
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        XCTAssertEqual(timeline.events.count, 15)
        XCTAssertEqual(timeline.totalBeats, 16)
        XCTAssertEqual(timeline.initialBPM, 80)
        XCTAssertEqual(timeline.measureStartBeats, [0, 4, 8, 12])
        XCTAssertEqual(timeline.measureNumbers, ["1", "2", "3", "4"])
        XCTAssertEqual(timeline.keyFifths, 2)
        XCTAssertEqual(timeline.events.first?.midiSounding, 50)
        XCTAssertEqual(timeline.events.first?.measureIndex, 0)
        XCTAssertEqual(timeline.events.last?.durationBeats, 2)
        XCTAssertEqual(timeline.events.last?.startBeat, 14)
        XCTAssertEqual(timeline.events.last?.measureIndex, 3)
        XCTAssertEqual(timeline.measureIndex(forBeat: 5.5), 1)
        XCTAssertEqual(timeline.measureIndex(forBeat: 0), 0)
        XCTAssertEqual(timeline.measureIndex(forBeat: 99), 3)
        let range = timeline.beatRange(fromMeasure: 1, toMeasure: 2)
        XCTAssertEqual(range.start, 4)
        XCTAssertEqual(range.end, 12)
        XCTAssertEqual(timeline.endBeat(ofMeasure: 3), 16)
    }

    func testTimelineUsesPreferredBPMAndTransposition() throws {
        let score = try MusicXMLParser.parse(try demoXML())
        let timeline = PlaybackTimeline(score: score, transposition: -12, preferredBPM: 100)
        XCTAssertEqual(timeline.initialBPM, 100)
        XCTAssertEqual(timeline.events.first?.midiSounding, 38)
        XCTAssertEqual(timeline.transposition, -12)
    }

    func testTimelineDefaultsToEightyWithoutTempo() throws {
        let xml = """
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note>
        </measure></part></score-partwise>
        """
        let score = try MusicXMLParser.parse(xml)
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        XCTAssertEqual(timeline.initialBPM, 80)
        XCTAssertEqual(timeline.totalBeats, 4)
    }

    func testTiedNotesMergeAndRestsAreDropped() throws {
        let score = try MusicXMLParser.parse(richXML)
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        // D, F(tied, 2+... ), A(chord), G, A, B♭ = 6 sounding notes; the rest and grace note are not events
        XCTAssertEqual(timeline.events.count, 6)
        let f = try XCTUnwrap(timeline.events.first { $0.midiSounding == 53 })
        XCTAssertEqual(f.startBeat, 2)
        XCTAssertEqual(f.durationBeats, 2, "tie across the barline merged")
        XCTAssertEqual(f.measureIndex, 0)
        let chordA = try XCTUnwrap(timeline.events.first { $0.midiSounding == 57 && $0.startBeat == 2 })
        XCTAssertEqual(chordA.durationBeats, 1)
        XCTAssertEqual(timeline.totalBeats, 6)
    }

    func testSoundingTransposition() {
        let plain = Score()
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .doubleBass, score: plain), -12)
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .piccolo, score: plain), 12)
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .cello, score: plain), 0)
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .clarinet, score: plain), 0)
        let written = Score(transposeChromatic: -2, transposeOctaveChange: 0)
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .clarinet, score: written), -2)
        XCTAssertEqual(PlaybackTimeline.soundingTransposition(for: .doubleBass, score: written), -2, "the part's own <transpose> wins")
    }

    func testTempoMapAndSeconds() throws {
        let score = try MusicXMLParser.parse(richXML) // 120 at 0, 90 at beat 6
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        XCTAssertEqual(timeline.initialBPM, 120)
        let map = timeline.tempoMap(baseBPM: 60)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[0].bpm, 60)
        XCTAssertEqual(map[1].beat, 6)
        XCTAssertEqual(map[1].bpm, 45, accuracy: 1e-9)
        XCTAssertEqual(timeline.seconds(atBeat: 4, targetBPM: 120), 2, accuracy: 1e-9)
        XCTAssertEqual(timeline.seconds(atBeat: 4, targetBPM: 60), 4, accuracy: 1e-9)
    }

    func testCountInFollowsTimeSignature() throws {
        let score = try MusicXMLParser.parse(richXML) // 3/4
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        let countIn = timeline.countIn(bars: 1)
        XCTAssertEqual(countIn.clicksPerBar, 3)
        XCTAssertEqual(countIn.clickSpacingBeats, 1)
        XCTAssertEqual(countIn.totalBeats, 3)
        XCTAssertEqual(countIn.clickCount, 3)

        let sixEight = Score(timeSignatures: [TimeSignatureChange(beat: 0, beats: 6, beatType: 8)])
        let t2 = PlaybackTimeline(score: sixEight, transposition: 0, preferredBPM: nil)
        let c2 = t2.countIn(bars: 2)
        XCTAssertEqual(c2.clicksPerBar, 6)
        XCTAssertEqual(c2.clickSpacingBeats, 0.5)
        XCTAssertEqual(c2.totalBeats, 6)
    }

    // MARK: MIDI writer

    func testVariableLengthQuantities() {
        XCTAssertEqual(MIDIFileWriter.vlq(0x0FFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertEqual(MIDIFileWriter.vlq(0), [0x00])
        XCTAssertEqual(MIDIFileWriter.vlq(0x7F), [0x7F])
        XCTAssertEqual(MIDIFileWriter.vlq(0x80), [0x81, 0x00])
        XCTAssertEqual(MIDIFileWriter.vlq(0x2000), [0xC0, 0x00])
        XCTAssertEqual(MIDIFileWriter.vlq(0x3FFF), [0xFF, 0x7F])
        XCTAssertEqual(MIDIFileWriter.vlq(0x4000), [0x81, 0x80, 0x00])
    }

    func testHeaderBytes() throws {
        let score = try MusicXMLParser.parse(try demoXML())
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        let result = MIDIFileWriter.write(timeline: timeline, program: Instrument.cello.gmProgram, baseBPM: 80, countIn: nil)
        let bytes = [UInt8](result.data)
        XCTAssertGreaterThan(bytes.count, 14)
        XCTAssertEqual(Array(bytes[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(bytes[4..<8]), [0x00, 0x00, 0x00, 0x06])
        XCTAssertEqual(Array(bytes[8..<10]), [0x00, 0x01], "format 1")
        XCTAssertEqual(Array(bytes[10..<12]), [0x00, 0x02], "tempo track + note track")
        XCTAssertEqual(Array(bytes[12..<14]), [0x01, 0xE0], "480 ticks per quarter")
        XCTAssertEqual(Array(bytes[14..<18]), Array("MTrk".utf8))
        XCTAssertEqual(result.countInBeats, 0)
        XCTAssertFalse(result.hasClickTrack)
        // Every track ends with End of Track.
        XCTAssertEqual(Array(bytes.suffix(3)), [0xFF, 0x2F, 0x00])
    }

    func testCountInAddsClickTrackAndShiftsMusic() throws {
        let score = try MusicXMLParser.parse(try demoXML())
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        let result = MIDIFileWriter.write(timeline: timeline, program: 42, baseBPM: 80, countIn: timeline.countIn(bars: 1))
        let bytes = [UInt8](result.data)
        XCTAssertEqual(Array(bytes[10..<12]), [0x00, 0x03], "tempo + notes + clicks")
        XCTAssertTrue(result.hasClickTrack)
        XCTAssertEqual(result.countInBeats, 4)
        XCTAssertEqual(MIDIFileWriter.ticks(forBeat: 4), 1920)
        // The note track starts with a program change on channel 0 at delta 0, then the first note-on
        // after a delta of 1920 ticks (VLQ 0x8F 0x00).
        let noteTrackStart = try XCTUnwrap(PracticeTests.trackOffsets(in: bytes).dropFirst().first)
        let body = Array(bytes[(noteTrackStart + 8)...])
        XCTAssertEqual(Array(body[0..<3]), [0x00, 0xC0, 42])
        XCTAssertEqual(Array(body[3..<5]), [0x8F, 0x00], "delta 1920 before the first note")
        XCTAssertEqual(body[5], 0x90, "note on, channel 0")
        XCTAssertEqual(body[6], 50, "D3")
        // Click track: first click is the woodblock downbeat on channel 9 at delta 0.
        let clickTrackStart = try XCTUnwrap(PracticeTests.trackOffsets(in: bytes).dropFirst(2).first)
        let clicks = Array(bytes[(clickTrackStart + 8)...])
        XCTAssertEqual(Array(clicks[0..<3]), [0x00, 0x99, 76])
    }

    func testMetaEvents() {
        XCTAssertEqual(MIDIFileWriter.tempoMeta(bpm: 120), [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
        XCTAssertEqual(MIDIFileWriter.microsecondsPerQuarter(bpm: 80), 750_000)
        XCTAssertEqual(MIDIFileWriter.timeSignatureMeta(TimeSignatureChange(beat: 0, beats: 6, beatType: 8)),
                       [0xFF, 0x58, 0x04, 6, 3, 24, 8])
        XCTAssertEqual(MIDIFileWriter.timeSignatureMeta(TimeSignatureChange(beat: 0, beats: 4, beatType: 4)),
                       [0xFF, 0x58, 0x04, 4, 2, 24, 8])
    }

    /// Byte offsets of every "MTrk" chunk header.
    private static func trackOffsets(in bytes: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        var i = 14
        while i + 8 <= bytes.count {
            if bytes[i] == 0x4D, bytes[i + 1] == 0x54, bytes[i + 2] == 0x72, bytes[i + 3] == 0x6B {
                offsets.append(i)
                let length = (Int(bytes[i + 4]) << 24) | (Int(bytes[i + 5]) << 16) | (Int(bytes[i + 6]) << 8) | Int(bytes[i + 7])
                i += 8 + length
            } else {
                i += 1
            }
        }
        return offsets
    }

    // MARK: Player helpers

    func testAudioFileName() {
        XCTAssertEqual(PracticeExport.audioFileName(for: "Strauss · Don Juan"), "Strauss-Don-Juan.m4a")
        XCTAssertEqual(PracticeExport.audioFileName(for: "   "), "Auditioner-reference.m4a")
        XCTAssertEqual(PracticeExport.audioFileName(for: "Demo: D major scale"), "Demo-D-major-scale.m4a")
    }
}
