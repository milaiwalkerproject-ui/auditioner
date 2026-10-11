import XCTest
@testable import Auditioner

/// Correction editor: XML tree round trip, every edit operation, the bar check, undo/redo and the
/// plain helpers. Fixtures are synthetic scales and rhythms (no real excerpt facts).
final class EditorTests: XCTestCase {

    // MARK: Fixtures

    /// C major, 4/4, two bars of quarters. Written so that serializing it again gives exactly this text.
    private static let scaleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">
      <!-- a comment the editor keeps -->
      <work><work-title>Test &amp; check</work-title></work>
      <part-list>
        <score-part id="P1"><part-name>Cello</part-name></score-part>
      </part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>1</divisions>
            <key><fifths>0</fifths></key>
            <time><beats>4</beats><beat-type>4</beat-type></time>
            <clef><sign>F</sign><line>4</line></clef>
          </attributes>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type></note>
          <note><pitch><step>D</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type></note>
          <note><pitch><step>E</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type><beam number="1">begin</beam></note>
          <note><pitch><step>F</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type><beam number="1">end</beam></note>
        </measure>
        <measure number="2">
          <note><pitch><step>G</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type><mystery-element kind="x">keep me</mystery-element></note>
          <note><pitch><step>A</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type></note>
          <note><pitch><step>B</step><octave>3</octave></pitch><duration>1</duration><type>quarter</type></note>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// F major, 3/4, with a grace note, a chord, a second voice, a tie across the barline and a whole-bar rest.
    private static let richXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Cello</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes>
            <divisions>2</divisions>
            <key><fifths>-1</fifths></key>
            <time><beats>3</beats><beat-type>4</beat-type></time>
            <clef><sign>F</sign><line>4</line></clef>
          </attributes>
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
        </measure>
        <measure number="3">
          <note><rest measure="yes"/><duration>6</duration><voice>1</voice></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// D major, 3/4 with a one-beat pickup bar, one bar in 2/4 (with too many notes), back to 3/4 and a
    /// short last bar that completes the pickup.
    private static let pickupXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Cello</part-name></score-part></part-list>
      <part id="P1">
        <measure implicit="yes" number="0">
          <attributes><divisions>2</divisions><key><fifths>2</fifths></key><time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>
          <note><pitch><step>A</step><octave>2</octave></pitch><duration>2</duration><type>quarter</type></note>
        </measure>
        <measure number="1">
          <note><pitch><step>D</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><pitch><step>E</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><pitch><step>F</step><alter>1</alter><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
        </measure>
        <measure number="2">
          <attributes><time><beats>2</beats><beat-type>4</beat-type></time></attributes>
          <note><pitch><step>G</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><pitch><step>A</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><pitch><step>B</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
        </measure>
        <measure number="3">
          <attributes><time><beats>3</beats><beat-type>4</beat-type></time></attributes>
          <note><pitch><step>D</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
          <note><pitch><step>E</step><octave>3</octave></pitch><duration>2</duration><type>quarter</type></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// Bass clef, 4/4: a rest first, then a note (for the "rest → note with no note before it" case).
    private static let restFirstXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Cello</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>
          <note><rest/><duration>2</duration><type>half</type></note>
          <note><pitch><step>G</step><octave>3</octave></pitch><duration>2</duration><type>half</type></note>
        </measure>
      </part>
    </score-partwise>
    """

    /// 6/8 bar with five eighths (one too few).
    private static let sixEightXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <part-list><score-part id="P1"><part-name>Horn</part-name></score-part></part-list>
      <part id="P1">
        <measure number="1">
          <attributes><divisions>2</divisions><time><beats>6</beats><beat-type>8</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
          <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
          <note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
          <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
          <note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
          <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
        </measure>
      </part>
    </score-partwise>
    """

    private func tree(_ xml: String) throws -> MusicXMLTree {
        try MusicXMLTree.parse(xml)
    }

    private func note(_ measure: Int, _ index: Int, in tree: MusicXMLTree) throws -> MusicXMLElement {
        try XCTUnwrap(ScoreEditing.note(at: NoteAddress(measureIndex: measure, noteIndex: index), in: tree))
    }

    private func pitchText(_ note: MusicXMLElement) -> String {
        guard let s = ScoreEditing.spelling(of: note) else { return "rest" }
        let alter = s.alter == 0 ? "" : (s.alter > 0 ? String(repeating: "#", count: s.alter) : String(repeating: "b", count: -s.alter))
        return "\(s.step)\(alter)\(s.octave)"
    }

    // MARK: Tree

    func testTreeRoundTripIsExact() throws {
        let t = try tree(EditorTests.scaleXML)
        XCTAssertEqual(t.root.name, "score-partwise")
        XCTAssertEqual(t.root.attribute("version"), "4.0")
        XCTAssertEqual(t.doctype, "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        XCTAssertEqual(t.serialized(), EditorTests.scaleXML + "\n")
        // And again from the output.
        let again = try tree(t.serialized())
        XCTAssertEqual(again.serialized(), t.serialized())
    }

    func testTreeKeepsTextCommentsAndUnknownElements() throws {
        let t = try tree(EditorTests.scaleXML)
        let title = try XCTUnwrap(t.root.firstChild(named: "work")?.firstChild(named: "work-title"))
        XCTAssertEqual(title.text, "Test & check")
        let hasComment = t.root.children.contains { node in
            if case .comment(let c) = node { return c.contains("a comment the editor keeps") }
            return false
        }
        XCTAssertTrue(hasComment)
        let g = try note(1, 0, in: t)
        let mystery = try XCTUnwrap(g.firstChild(named: "mystery-element"))
        XCTAssertEqual(mystery.attribute("kind"), "x")
        XCTAssertEqual(mystery.text, "keep me")
    }

    func testTreeEscapesTextAndAttributes() throws {
        let element = MusicXMLElement(name: "credit-words", attributes: [MusicXMLAttribute(name: "font", value: "A \"B\" & <C>")], children: [.text("Fish & Chips <b>")])
        let t = MusicXMLTree(root: element)
        let xml = t.serialized()
        XCTAssertTrue(xml.contains("font=\"A &quot;B&quot; &amp; &lt;C&gt;\""), xml)
        XCTAssertTrue(xml.contains(">Fish &amp; Chips &lt;b&gt;<"), xml)
        let back = try tree(xml)
        XCTAssertEqual(back.root.text, "Fish & Chips <b>")
        XCTAssertEqual(back.root.attribute("font"), "A \"B\" & <C>")
        XCTAssertNil(back.doctype)
        XCTAssertTrue(xml.hasPrefix(MusicXMLTree.declaration + "\n<credit-words"))
    }

    func testTreeEmptyElementsAndEditingHelpers() throws {
        let t = try tree(EditorTests.richXML)
        let d = try note(0, 0, in: t)
        XCTAssertNil(d.firstChild(named: "grace"))
        // <grace/> round-trips as a self-closing element.
        XCTAssertTrue(t.serialized().contains("<grace/>"))
        let pitch = try XCTUnwrap(d.firstChild(named: "pitch"))
        XCTAssertEqual(pitch.childElements.map { $0.name }, ["step", "octave"])
        pitch.setText("x")
        XCTAssertEqual(pitch.children.count, 1)
        let copy = d.deepCopy()
        XCTAssertFalse(copy === d)
        XCTAssertEqual(copy.firstChild(named: "duration")?.text, "2")
        copy.setAttribute("id", to: "n1")
        XCTAssertEqual(copy.attribute("id"), "n1")
        XCTAssertNil(d.attribute("id"))
        copy.setAttribute("id", to: nil)
        XCTAssertNil(copy.attribute("id"))
    }

    func testTreeMalformedThrows() {
        XCTAssertThrowsError(try MusicXMLTree.parse("<score-partwise><part><measure>"))
        XCTAssertThrowsError(try MusicXMLTree.parse(""))
    }

    func testDoctypeScanner() {
        XCTAssertNil(MusicXMLTree.doctype(in: "<?xml version=\"1.0\"?><a/>"))
        XCTAssertEqual(MusicXMLTree.doctype(in: "<?xml version=\"1.0\"?>\n<!DOCTYPE a [ <!ENTITY x \"y\"> ]>\n<a/>"),
                       "<!DOCTYPE a [ <!ENTITY x \"y\"> ]>")
        XCTAssertNil(MusicXMLTree.doctype(in: "<a><!DOCTYPE b></a>"), "a DOCTYPE after the root element is not one")
    }

    // MARK: Addressing

    func testAddressingSkipsGraceChordMembersAndOtherVoices() throws {
        let t = try tree(EditorTests.richXML)
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [3, 4, 1])
        XCTAssertEqual(ScoreEditing.measureNumbers(in: t), ["1", "2", "3"])
        XCTAssertEqual(pitchText(try note(0, 0, in: t)), "D3")
        XCTAssertEqual(pitchText(try note(0, 1, in: t)), "rest")
        XCTAssertEqual(pitchText(try note(0, 2, in: t)), "F3")
        XCTAssertNil(ScoreEditing.note(at: NoteAddress(measureIndex: 0, noteIndex: 3), in: t))
        XCTAssertNil(ScoreEditing.note(at: NoteAddress(measureIndex: 9, noteIndex: 0), in: t))
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 2, in: t), 2)
        XCTAssertEqual(ScoreEditing.keyFifths(atMeasure: 1, in: t), -1)
        XCTAssertEqual(ScoreEditing.clef(atMeasure: 2, in: t)?.sign, "F")
        let f = try note(0, 2, in: t)
        let bar = try XCTUnwrap(ScoreEditing.measure(at: 0, in: t))
        XCTAssertEqual(ScoreEditing.chordMembers(of: f, in: bar).count, 1)
    }

    // MARK: Pitch

    func testPitchUpAndDownRespellInCMajor() throws {
        let t = try tree(EditorTests.scaleXML)
        try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 2), by: 1, in: t)   // E3 → F3
        XCTAssertEqual(pitchText(try note(0, 2, in: t)), "F3")
        XCTAssertNil(try note(0, 2, in: t).firstChild(named: "accidental"))

        try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 3), by: 1, in: t)   // F3 → F#3
        let fSharp = try note(0, 3, in: t)
        XCTAssertEqual(pitchText(fSharp), "F#3")
        XCTAssertEqual(fSharp.firstChild(named: "accidental")?.text, "sharp")
        XCTAssertEqual(fSharp.firstChild(named: "pitch")?.childElements.map { $0.name }, ["step", "alter", "octave"])

        try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 3), by: -1, in: t)  // F#3 → F3 (natural in C: no sign needed)
        XCTAssertEqual(pitchText(try note(0, 3, in: t)), "F3")
        XCTAssertNil(try note(0, 3, in: t).firstChild(named: "accidental"))

        try ScoreEditing.transpose(NoteAddress(measureIndex: 1, noteIndex: 3), by: -1, in: t)  // C4 → B3 (octave down)
        XCTAssertEqual(pitchText(try note(1, 3, in: t)), "B3")

        try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 2), by: -2, in: t)  // F3 → Eb3 going down: flat
        let eFlat = try note(0, 2, in: t)
        XCTAssertEqual(pitchText(eFlat), "Eb3")
        XCTAssertEqual(eFlat.firstChild(named: "accidental")?.text, "flat")

        try ScoreEditing.transpose(NoteAddress(measureIndex: 1, noteIndex: 3), by: 1, in: t)   // B3 → C4 (octave up)
        XCTAssertEqual(pitchText(try note(1, 3, in: t)), "C4")

        // The result still parses as a score with the expected MIDI numbers.
        let score = try MusicXMLParser.parse(t.serialized())
        XCTAssertEqual(score.measures[0].notes[2].midi, 51)
        XCTAssertEqual(score.measures[0].notes[3].midi, 53)
    }

    func testPitchFollowsFlatKeySignature() throws {
        let t = try tree(EditorTests.richXML) // F major
        try ScoreEditing.transpose(NoteAddress(measureIndex: 1, noteIndex: 2), by: 1, in: t)   // A3 → Bb3 (in key: no sign)
        let bFlat = try note(1, 2, in: t)
        XCTAssertEqual(pitchText(bFlat), "Bb3")
        XCTAssertNil(bFlat.firstChild(named: "accidental"))
        try ScoreEditing.transpose(NoteAddress(measureIndex: 1, noteIndex: 2), by: 1, in: t)   // Bb3 → B3: needs a natural
        let bNatural = try note(1, 2, in: t)
        XCTAssertEqual(pitchText(bNatural), "B3")
        XCTAssertEqual(bNatural.firstChild(named: "accidental")?.text, "natural")
    }

    func testPitchOnRestThrows() throws {
        let t = try tree(EditorTests.richXML)
        XCTAssertThrowsError(try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 1), by: 1, in: t)) { error in
            XCTAssertEqual(error as? ScoreEditError, ScoreEditError.notPitched)
        }
        XCTAssertThrowsError(try ScoreEditing.transpose(NoteAddress(measureIndex: 5, noteIndex: 1), by: 1, in: t)) { error in
            XCTAssertEqual(error as? ScoreEditError, ScoreEditError.noNote(NoteAddress(measureIndex: 5, noteIndex: 1)))
        }
    }

    func testSetAccidental() throws {
        let t = try tree(EditorTests.scaleXML)
        let address = NoteAddress(measureIndex: 0, noteIndex: 0)
        try ScoreEditing.setAccidental(address, .sharp, in: t)
        XCTAssertEqual(pitchText(try note(0, 0, in: t)), "C#3")
        XCTAssertEqual(try note(0, 0, in: t).firstChild(named: "accidental")?.text, "sharp")
        try ScoreEditing.setAccidental(address, .flat, in: t)
        XCTAssertEqual(pitchText(try note(0, 0, in: t)), "Cb3")
        XCTAssertEqual(try note(0, 0, in: t).firstChild(named: "accidental")?.text, "flat")
        try ScoreEditing.setAccidental(address, .natural, in: t)
        XCTAssertEqual(pitchText(try note(0, 0, in: t)), "C3")
        XCTAssertEqual(try note(0, 0, in: t).firstChild(named: "accidental")?.text, "natural")
        try ScoreEditing.setAccidental(address, .none, in: t)
        XCTAssertEqual(pitchText(try note(0, 0, in: t)), "C3")
        XCTAssertNil(try note(0, 0, in: t).firstChild(named: "accidental"))
        XCTAssertNil(try note(0, 0, in: t).firstChild(named: "pitch")?.firstChild(named: "alter"))

        // "No sign" in a sharp key gives the key's sharp back.
        let p = try tree(EditorTests.pickupXML) // D major
        try ScoreEditing.setAccidental(NoteAddress(measureIndex: 1, noteIndex: 2), .natural, in: p) // F#3 → F natural
        XCTAssertEqual(pitchText(try note(1, 2, in: p)), "F3")
        XCTAssertEqual(try note(1, 2, in: p).firstChild(named: "accidental")?.text, "natural")
        try ScoreEditing.setAccidental(NoteAddress(measureIndex: 1, noteIndex: 2), .none, in: p)
        XCTAssertEqual(pitchText(try note(1, 2, in: p)), "F#3")
        XCTAssertNil(try note(1, 2, in: p).firstChild(named: "accidental"))
    }

    // MARK: Duration

    func testSetDurationScalesDivisionsAndStripsBeams() throws {
        let t = try tree(EditorTests.scaleXML)
        try ScoreEditing.setDuration(NoteAddress(measureIndex: 0, noteIndex: 2), .eighth, in: t)
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 0, in: t), 2, "divisions doubled so an eighth is a whole number")
        let e = try note(0, 2, in: t)
        XCTAssertEqual(e.firstChild(named: "type")?.text, "eighth")
        XCTAssertEqual(e.firstChild(named: "duration")?.text, "1")
        XCTAssertEqual(try note(0, 0, in: t).firstChild(named: "duration")?.text, "2", "other notes rescaled")
        XCTAssertEqual(try note(1, 3, in: t).firstChild(named: "duration")?.text, "2")
        XCTAssertNil(e.firstChild(named: "beam"))
        XCTAssertNil(try note(0, 3, in: t).firstChild(named: "beam"))
        // Element order inside <note> is kept valid.
        XCTAssertEqual(e.childElements.map { $0.name }, ["pitch", "duration", "type"])

        let score = try MusicXMLParser.parse(t.serialized())
        XCTAssertEqual(score.measures[0].notes[2].durationBeats, 0.5)
        XCTAssertEqual(score.measures[0].lengthBeats, 3.5)
        XCTAssertEqual(ScoreEditing.barCheck(in: t).map { $0.measureNumber }, ["1"])

        try ScoreEditing.setDuration(NoteAddress(measureIndex: 0, noteIndex: 2), .half, in: t)
        XCTAssertEqual(try note(0, 2, in: t).firstChild(named: "duration")?.text, "4")
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 0, in: t), 2, "no rescale needed for a half")
    }

    func testSetDurationOnChordAndThirtySecond() throws {
        let t = try tree(EditorTests.richXML)
        try ScoreEditing.setDuration(NoteAddress(measureIndex: 0, noteIndex: 2), .thirtySecond, in: t)
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 0, in: t), 8)
        let f = try note(0, 2, in: t)
        let bar = try XCTUnwrap(ScoreEditing.measure(at: 0, in: t))
        let a = try XCTUnwrap(ScoreEditing.chordMembers(of: f, in: bar).first)
        XCTAssertEqual(f.firstChild(named: "duration")?.text, "1")
        XCTAssertEqual(a.firstChild(named: "duration")?.text, "1")
        XCTAssertEqual(a.firstChild(named: "type")?.text, "32nd")
        // The <backup> and voice 2 were rescaled too, so the second voice still fills the bar.
        let backup = try XCTUnwrap(bar.firstChild(named: "backup"))
        XCTAssertEqual(backup.firstChild(named: "duration")?.text, "24")
    }

    func testToggleDot() throws {
        let t = try tree(EditorTests.scaleXML)
        let address = NoteAddress(measureIndex: 0, noteIndex: 0)
        try ScoreEditing.toggleDot(address, in: t)
        var c = try note(0, 0, in: t)
        XCTAssertEqual(c.children(named: "dot").count, 1)
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 0, in: t), 2)
        XCTAssertEqual(c.firstChild(named: "duration")?.text, "3")
        XCTAssertEqual(c.childElements.map { $0.name }, ["pitch", "duration", "type", "dot"])
        try ScoreEditing.toggleDot(address, in: t)
        c = try note(0, 0, in: t)
        XCTAssertEqual(c.children(named: "dot").count, 0)
        XCTAssertEqual(c.firstChild(named: "duration")?.text, "2")
        XCTAssertEqual(BeatFraction.dotFactor(dots: 2), BeatFraction(7, 4))
        XCTAssertEqual(BeatFraction(6, 4), BeatFraction(3, 2))
        XCTAssertEqual((BeatFraction(1, 2) * BeatFraction(2, 3)).doubleValue, 1.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: Note ↔ rest

    func testNoteToRestAndBack() throws {
        let t = try tree(EditorTests.scaleXML)
        let address = NoteAddress(measureIndex: 0, noteIndex: 1)
        try ScoreEditing.toggleRest(address, in: t)
        var d = try note(0, 1, in: t)
        XCTAssertNotNil(d.firstChild(named: "rest"))
        XCTAssertNil(d.firstChild(named: "pitch"))
        XCTAssertEqual(d.firstChild(named: "duration")?.text, "1")
        XCTAssertEqual(d.childElements.map { $0.name }, ["rest", "duration", "type"])
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [4, 4])

        try ScoreEditing.toggleRest(address, in: t)
        d = try note(0, 1, in: t)
        XCTAssertNil(d.firstChild(named: "rest"))
        XCTAssertEqual(pitchText(d), "C3", "takes the pitch of the previous note")
        XCTAssertEqual(d.childElements.map { $0.name }, ["pitch", "duration", "type"])
    }

    func testWholeBarRestBecomesNoteAndChordBecomesOneRest() throws {
        let t = try tree(EditorTests.richXML)
        try ScoreEditing.toggleRest(NoteAddress(measureIndex: 2, noteIndex: 0), in: t)
        let n = try note(2, 0, in: t)
        XCTAssertEqual(pitchText(n), "Bb3", "previous pitched note")
        XCTAssertEqual(n.firstChild(named: "type")?.text, "quarter", "6 divisions in 3/4 is no plain value, so a quarter")
        XCTAssertEqual(n.firstChild(named: "duration")?.text, "2")
        XCTAssertNil(n.firstChild(named: "rest"))

        // Chord → one rest; its tie to bar 2 is cleared on both sides.
        try ScoreEditing.toggleRest(NoteAddress(measureIndex: 0, noteIndex: 2), in: t)
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [3, 4, 1])
        let bar = try XCTUnwrap(ScoreEditing.measure(at: 0, in: t))
        XCTAssertEqual(bar.children(named: "note").filter { $0.firstChild(named: "chord") != nil }.count, 0)
        let rest = try note(0, 2, in: t)
        XCTAssertNotNil(rest.firstChild(named: "rest"))
        XCTAssertTrue(rest.children(named: "tie").isEmpty)
        XCTAssertNil(rest.firstChild(named: "notations"))
        let next = try note(1, 0, in: t)
        XCTAssertFalse(ScoreEditing.hasTie(next, type: "stop"))
        XCTAssertNil(next.firstChild(named: "notations"))

        // A rest with no note before it takes the clef's middle line (D3 in bass clef).
        let first = try tree(EditorTests.restFirstXML)
        try ScoreEditing.toggleRest(NoteAddress(measureIndex: 0, noteIndex: 0), in: first)
        XCTAssertEqual(pitchText(try note(0, 0, in: first)), "D3")
        XCTAssertEqual(try note(0, 0, in: first).firstChild(named: "type")?.text, "half", "keeps the rest's length")
        XCTAssertEqual(ScoreEditing.barCheck(in: first), [])
        XCTAssertEqual(ScoreEditing.defaultPitch(forClef: (sign: "F", line: 4)), ScoreEditing.Spelling(step: "D", alter: 0, octave: 3))
        XCTAssertEqual(ScoreEditing.defaultPitch(forClef: (sign: "G", line: 2)).step, "B")
        XCTAssertEqual(ScoreEditing.defaultPitch(forClef: (sign: "C", line: 4)).step, "A")
        XCTAssertEqual(ScoreEditing.defaultPitch(forClef: nil).octave, 4)
    }

    // MARK: Delete / insert

    func testDeleteNoteClearsTiesAndChord() throws {
        let t = try tree(EditorTests.richXML)
        try ScoreEditing.deleteNote(NoteAddress(measureIndex: 1, noteIndex: 0), in: t)   // the tied-to F in bar 2
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [3, 3, 1])
        let f = try note(0, 2, in: t)
        XCTAssertFalse(ScoreEditing.hasTie(f, type: "start"), "tie start removed when its partner went")
        XCTAssertNil(f.firstChild(named: "notations"))
        try ScoreEditing.deleteNote(NoteAddress(measureIndex: 0, noteIndex: 2), in: t)   // the chord
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [2, 3, 1])
        let bar = try XCTUnwrap(ScoreEditing.measure(at: 0, in: t))
        XCTAssertEqual(bar.children(named: "note").count, 4, "grace + D + rest + voice 2 remain")
        XCTAssertNotNil(bar.firstChild(named: "backup"), "other voices untouched")
        try ScoreEditing.deleteNote(NoteAddress(measureIndex: 2, noteIndex: 0), in: t)
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [2, 3, 0])
        XCTAssertThrowsError(try ScoreEditing.deleteNote(NoteAddress(measureIndex: 2, noteIndex: 0), in: t))
    }

    func testInsertNoteAfterCopiesWithoutTiesOrBeams() throws {
        let t = try tree(EditorTests.richXML)
        let inserted = try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 2), in: t)
        XCTAssertEqual(inserted, NoteAddress(measureIndex: 0, noteIndex: 3))
        XCTAssertEqual(ScoreEditing.noteCounts(in: t), [4, 4, 1])
        let copy = try note(0, 3, in: t)
        XCTAssertEqual(pitchText(copy), "F3")
        XCTAssertEqual(copy.firstChild(named: "type")?.text, "quarter")
        XCTAssertTrue(copy.children(named: "tie").isEmpty)
        XCTAssertNil(copy.firstChild(named: "notations"))
        XCTAssertNil(copy.firstChild(named: "chord"))
        let original = try note(0, 2, in: t)
        XCTAssertTrue(ScoreEditing.hasTie(original, type: "start"), "the original keeps its tie")
        // The copy sits after the chord member, so the chord is still intact.
        let bar = try XCTUnwrap(ScoreEditing.measure(at: 0, in: t))
        let names = bar.children(named: "note").map { $0.firstChild(named: "chord") != nil ? "chord" : pitchText($0) }
        XCTAssertEqual(names, ["C3", "D3", "rest", "F3", "chord", "F3", "C2"])
        XCTAssertEqual(ScoreEditing.barCheck(in: t).map { $0.measureIndex }, [0])

        // Inserting after a rest copies the rest.
        try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 1), in: t)
        XCTAssertNotNil(try note(0, 2, in: t).firstChild(named: "rest"))
    }

    // MARK: Ties

    func testToggleTieAcrossBarline() throws {
        let t = try tree(EditorTests.scaleXML)
        let last = NoteAddress(measureIndex: 0, noteIndex: 3)
        XCTAssertEqual(ScoreEditing.nextAddress(after: last, in: t), NoteAddress(measureIndex: 1, noteIndex: 0))
        try ScoreEditing.toggleTie(last, in: t)
        let f = try note(0, 3, in: t)
        let g = try note(1, 0, in: t)
        XCTAssertTrue(ScoreEditing.hasTie(f, type: "start"))
        XCTAssertTrue(ScoreEditing.hasTie(g, type: "stop"))
        XCTAssertEqual(f.firstChild(named: "notations")?.firstChild(named: "tied")?.attribute("type"), "start")
        XCTAssertEqual(g.firstChild(named: "notations")?.firstChild(named: "tied")?.attribute("type"), "stop")
        XCTAssertEqual(f.childElements.map { $0.name }, ["pitch", "duration", "tie", "type", "beam", "notations"])
        XCTAssertEqual(g.childElements.map { $0.name }, ["pitch", "duration", "tie", "type", "mystery-element", "notations"])

        try ScoreEditing.toggleTie(last, in: t)
        XCTAssertFalse(ScoreEditing.hasTie(try note(0, 3, in: t), type: "start"))
        XCTAssertFalse(ScoreEditing.hasTie(try note(1, 0, in: t), type: "stop"))
        XCTAssertNil(try note(0, 3, in: t).firstChild(named: "notations"))
        XCTAssertNil(try note(1, 0, in: t).firstChild(named: "notations"))

        XCTAssertThrowsError(try ScoreEditing.toggleTie(NoteAddress(measureIndex: 1, noteIndex: 3), in: t)) { error in
            XCTAssertEqual(error as? ScoreEditError, ScoreEditError.noNextNote)
        }
        let r = try tree(EditorTests.richXML)
        XCTAssertThrowsError(try ScoreEditing.toggleTie(NoteAddress(measureIndex: 0, noteIndex: 1), in: r)) { error in
            XCTAssertEqual(error as? ScoreEditError, ScoreEditError.notPitched)
        }
        XCTAssertThrowsError(try ScoreEditing.toggleTie(NoteAddress(measureIndex: 0, noteIndex: 0), in: r), "next is a rest")
    }

    func testTiedNotesPlayAsOneAfterEditing() throws {
        let t = try tree(EditorTests.scaleXML)
        try ScoreEditing.toggleTie(NoteAddress(measureIndex: 0, noteIndex: 0), in: t)
        // Make the second note the same pitch so the tie is musically a tie.
        try ScoreEditing.transpose(NoteAddress(measureIndex: 0, noteIndex: 1), by: -2, in: t)
        let score = try MusicXMLParser.parse(t.serialized())
        let timeline = PlaybackTimeline(score: score, transposition: 0, preferredBPM: nil)
        XCTAssertEqual(timeline.events.count, 7)
        XCTAssertEqual(timeline.events.first?.durationBeats, 2)
    }

    // MARK: Bar check

    func testBarCheckFindsShortAndLongBars() throws {
        let full = try tree(EditorTests.scaleXML)
        XCTAssertEqual(ScoreEditing.barCheck(in: full), [])

        try ScoreEditing.deleteNote(NoteAddress(measureIndex: 1, noteIndex: 0), in: full)
        let short = ScoreEditing.barCheck(in: full)
        XCTAssertEqual(short, [BarCheckIssue(measureIndex: 1, measureNumber: "2", beats: 4, beatType: 4, expectedBeats: 4, actualBeats: 3)])

        try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 0), in: full)
        let both = ScoreEditing.barCheck(in: full)
        XCTAssertEqual(both.map { $0.measureIndex }, [0, 1])
        XCTAssertEqual(both[0].actualBeats, 5)
    }

    func testBarCheckAllowsPickupAndTracksTimeChange() throws {
        let t = try tree(EditorTests.pickupXML)
        let issues = ScoreEditing.barCheck(in: t)
        XCTAssertEqual(issues, [BarCheckIssue(measureIndex: 2, measureNumber: "2", beats: 2, beatType: 4, expectedBeats: 2, actualBeats: 3)],
                       "pickup bar 0 and the last bar that completes it (back in 3/4) are fine; bar 2 has 3 beats in 2/4")
        // A pickup that is too LONG is reported.
        try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 0), in: t)
        try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 0), in: t)
        try ScoreEditing.insertNoteAfter(NoteAddress(measureIndex: 0, noteIndex: 0), in: t)
        let longPickup = ScoreEditing.barCheck(in: t)
        XCTAssertEqual(longPickup.first?.measureIndex, 0)
        XCTAssertEqual(longPickup.first?.actualBeats, 4)
        XCTAssertEqual(longPickup.map { $0.measureIndex }, [0, 2, 3], "without a pickup the short last bar counts too")
    }

    func testBarCheckUsesTheBeatTypeAsUnit() throws {
        let t = try tree(EditorTests.sixEightXML)
        let issues = ScoreEditing.barCheck(in: t)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].expectedBeats, 6)
        XCTAssertEqual(issues[0].actualBeats, 5)
        XCTAssertEqual(issues[0].beatType, 8)
        XCTAssertEqual(EditorLogic.issueText(issues[0]), "Bar 1: 5 of 6 beats")
        XCTAssertEqual(ScoreEditing.parseBeats("3+2"), 5)
        XCTAssertNil(ScoreEditing.parseBeats("x"))
    }

    func testBarCheckWithoutTimeSignatureIsSilent() throws {
        let xml = """
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><type>quarter</type></note></measure></part></score-partwise>
        """
        let t = try tree(xml)
        XCTAssertEqual(ScoreEditing.barCheck(in: t), [])
        // No <divisions> written: scaling creates one.
        try ScoreEditing.setDuration(NoteAddress(measureIndex: 0, noteIndex: 0), .eighth, in: t)
        XCTAssertEqual(ScoreEditing.divisions(atMeasure: 0, in: t), 2)
        XCTAssertEqual(try note(0, 0, in: t).firstChild(named: "duration")?.text, "1")
        let score = try MusicXMLParser.parse(t.serialized())
        XCTAssertEqual(score.notes.first?.durationBeats, 0.5)
    }

    // MARK: Undo stack

    func testEditHistory() {
        var history = EditHistory(initial: "a")
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isDirty)
        history.push("b")
        history.push("c")
        XCTAssertTrue(history.isDirty)
        XCTAssertEqual(history.current, "c")
        XCTAssertEqual(history.undo(), "b")
        XCTAssertEqual(history.undo(), "a")
        XCTAssertNil(history.undo())
        XCTAssertFalse(history.isDirty)
        XCTAssertEqual(history.redo(), "b")
        history.push("d")
        XCTAssertFalse(history.canRedo, "a new edit drops what could be redone")
        XCTAssertEqual(history.states, ["a", "b", "d"])
        history.push("d")
        XCTAssertEqual(history.states.count, 3, "an unchanged state is not recorded")
        XCTAssertEqual(history.redo(), nil)
        for i in 0..<200 {
            history.push("state \(i)")
        }
        XCTAssertEqual(history.states.count, EditHistory.maximumStates)
        XCTAssertEqual(history.current, "state 199")
        XCTAssertEqual(history.initial, "a")
        XCTAssertTrue(history.isDirty)
    }

    // MARK: Editor helpers

    func testEditorLogicHelpers() {
        let numbers = ["0", "1", "2", "3"]
        XCTAssertEqual(EditorLogic.resolveMeasureIndex(tapIndex: 2, tapNumber: "2", measureNumbers: numbers), 2)
        XCTAssertEqual(EditorLogic.resolveMeasureIndex(tapIndex: 2, tapNumber: "", measureNumbers: numbers), 2)
        XCTAssertEqual(EditorLogic.resolveMeasureIndex(tapIndex: 9, tapNumber: "3", measureNumbers: numbers), 3, "falls back to the printed number")
        XCTAssertNil(EditorLogic.resolveMeasureIndex(tapIndex: 9, tapNumber: "x", measureNumbers: numbers))
        XCTAssertNil(EditorLogic.resolveMeasureIndex(tapIndex: -1, tapNumber: "", measureNumbers: numbers))

        let address = NoteAddress(measureIndex: 1, noteIndex: 2)
        XCTAssertEqual(EditorLogic.selectionAfterDelete(address, remainingNotesInMeasure: 3), address)
        XCTAssertEqual(EditorLogic.selectionAfterDelete(address, remainingNotesInMeasure: 2), NoteAddress(measureIndex: 1, noteIndex: 1))
        XCTAssertNil(EditorLogic.selectionAfterDelete(address, remainingNotesInMeasure: 0))

        XCTAssertEqual(EditorLogic.correctedTitle("Brahms 2"), "Brahms 2 (corrected)")
        XCTAssertEqual(EditorLogic.correctedTitle("Brahms 2 (corrected)"), "Brahms 2 (corrected)")

        XCTAssertEqual(EditorLogic.beatsText(4), "4")
        XCTAssertEqual(EditorLogic.beatsText(3.5), "3½")
        XCTAssertEqual(EditorLogic.beatsText(0.25), "¼")
        XCTAssertEqual(EditorLogic.beatsText(2.75), "2¾")
        XCTAssertEqual(EditorLogic.beatsText(0), "0")
        XCTAssertEqual(EditorLogic.beatsText(2.7), "2.70")
        let issue = BarCheckIssue(measureIndex: 2, measureNumber: "3", beats: 4, beatType: 4, expectedBeats: 4, actualBeats: 3.5)
        XCTAssertEqual(EditorLogic.issueText(issue), "Bar 3: 3½ of 4 beats")
    }

    func testNoteValues() {
        XCTAssertEqual(NoteValue.from(musicXMLType: "16th"), .sixteenth)
        XCTAssertEqual(NoteValue.from(musicXMLType: "Quarter"), .quarter)
        XCTAssertNil(NoteValue.from(musicXMLType: "breve"))
        XCTAssertEqual(NoteValue.thirtySecond.musicXMLType, "32nd")
        XCTAssertEqual(NoteValue.allCases.count, 6)
        XCTAssertEqual(ScoreEditing.keyAlteration(step: "F", fifths: 1), 1)
        XCTAssertEqual(ScoreEditing.keyAlteration(step: "C", fifths: 1), 0)
        XCTAssertEqual(ScoreEditing.keyAlteration(step: "B", fifths: -1), -1)
        XCTAssertEqual(ScoreEditing.keyAlteration(step: "E", fifths: -1), 0)
        XCTAssertEqual(ScoreEditing.spelling(midi: 61, preferFlats: false), ScoreEditing.Spelling(step: "C", alter: 1, octave: 4))
        XCTAssertEqual(ScoreEditing.spelling(midi: 61, preferFlats: true), ScoreEditing.Spelling(step: "D", alter: -1, octave: 4))
        XCTAssertEqual(ScoreEditing.spelling(midi: 59, preferFlats: true), ScoreEditing.Spelling(step: "B", alter: 0, octave: 3))
    }

    // MARK: Model

    @MainActor
    func testModelAppliesEditsWithUndoRedo() throws {
        let document = ScoreDocument(title: "Scale", musicXML: EditorTests.scaleXML, origin: .omr, instrument: .cello)
        let model = ScoreEditorModel(document: document)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.canEdit)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.measureNumbers, ["1", "2"])
        XCTAssertEqual(model.issues, [])

        model.apply(.pitchUp)
        XCTAssertNotNil(model.hint, "nothing selected yet")
        XCTAssertFalse(model.isDirty)

        model.select(tap: EditorNoteTap(measureIndex: 0, measureNumber: "1", noteOrder: 3, qstamp: 3))
        XCTAssertEqual(model.selection, NoteAddress(measureIndex: 0, noteIndex: 3))
        XCTAssertNil(model.hint)
        model.apply(.pitchUp)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(model.musicXML.contains("<accidental>sharp</accidental>"))
        XCTAssertEqual(model.correctedDocument.origin, .edited)
        XCTAssertEqual(model.correctedDocument.musicXML, model.musicXML)

        model.apply(.delete)
        XCTAssertEqual(model.selection, NoteAddress(measureIndex: 0, noteIndex: 2), "the note before is selected")
        XCTAssertEqual(model.issues.map { $0.measureIndex }, [0])
        XCTAssertEqual(model.flaggedMeasureIndices, [0])

        model.undo()
        XCTAssertEqual(model.issues, [])
        XCTAssertTrue(model.canRedo)
        model.undo()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.musicXML, EditorTests.scaleXML)
        model.redo()
        XCTAssertTrue(model.musicXML.contains("<accidental>sharp</accidental>"))

        model.select(tap: EditorNoteTap(measureIndex: 0, measureNumber: "1", noteOrder: -1, qstamp: 0))
        XCTAssertNotNil(model.hint, "a note from another voice can't be edited")
        model.clearHint()
        XCTAssertNil(model.hint)

        model.apply(.insertAfter)
        XCTAssertEqual(model.selection, NoteAddress(measureIndex: 0, noteIndex: 3))
        model.apply(.toggleRest)
        XCTAssertTrue(model.selectedIsRest)
        model.selectFirstNote(inMeasure: 1)
        XCTAssertEqual(model.selection, NoteAddress(measureIndex: 1, noteIndex: 0))
        model.apply(.toggleTie)
        XCTAssertTrue(model.selectedIsTied)
        model.apply(.toggleDot)
        XCTAssertTrue(model.selectedHasDot)
    }

    @MainActor
    func testModelRejectsBrokenFile() {
        let document = ScoreDocument(title: "Bad", musicXML: "<score-partwise><part>", origin: .omr, instrument: .cello)
        let model = ScoreEditorModel(document: document)
        XCTAssertNotNil(model.loadError)
        XCTAssertFalse(model.canEdit)
        model.select(tap: EditorNoteTap(measureIndex: 0, measureNumber: "1", noteOrder: 0, qstamp: 0))
        XCTAssertNil(model.selection)
    }
}
