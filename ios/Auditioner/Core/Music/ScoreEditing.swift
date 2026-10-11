import Foundation

// Edit operations for the correction editor, on a `MusicXMLTree`. They touch only the FIRST
// <part> and only voice 1. A note is addressed by (measure index, index among the measure's
// voice-1 notes that are neither grace notes nor <chord/> members) — a chord counts once, through
// its first note. Everything here is pure and synchronous so it can be unit-tested on fixtures.
//
// Spelling rule for pitch up/down (kept deliberately simple):
//   - in a key with flats (<fifths> < 0) black keys are spelled with flats,
//   - in a key with sharps (<fifths> > 0) with sharps,
//   - in C major / A minor: sharps when going up, flats when going down.
//   The written <accidental> is shown whenever the note's alteration differs from the key
//   signature, and removed when it matches it. Accidentals carried through the bar and courtesy
//   accidentals are not tracked.
//
// Structural edits (duration, dot, rest, delete, insert) remove <beam> marks from the measure:
// the notes are then drawn with flags, which is always correct, instead of with beams that no
// longer match.

/// Address of an editable note: measure index in the first part, index among that measure's
/// voice-1 non-grace, non-chord notes.
struct NoteAddress: Hashable, Codable {
    var measureIndex: Int
    var noteIndex: Int

    init(measureIndex: Int, noteIndex: Int) {
        self.measureIndex = measureIndex
        self.noteIndex = noteIndex
    }
}

/// Note values the palette offers.
enum NoteValue: String, CaseIterable, Identifiable {
    case whole = "whole"
    case half = "half"
    case quarter = "quarter"
    case eighth = "eighth"
    case sixteenth = "16th"
    case thirtySecond = "32nd"

    var id: String { rawValue }

    /// The MusicXML `<type>` text.
    var musicXMLType: String { rawValue }

    /// Length in quarter notes, undotted.
    var quarters: BeatFraction {
        switch self {
        case .whole: return BeatFraction(4, 1)
        case .half: return BeatFraction(2, 1)
        case .quarter: return BeatFraction(1, 1)
        case .eighth: return BeatFraction(1, 2)
        case .sixteenth: return BeatFraction(1, 4)
        case .thirtySecond: return BeatFraction(1, 8)
        }
    }

    /// Plain name for buttons.
    var label: String {
        switch self {
        case .whole: return String(localized: "Whole")
        case .half: return String(localized: "Half")
        case .quarter: return String(localized: "Quarter")
        case .eighth: return String(localized: "8th")
        case .sixteenth: return String(localized: "16th")
        case .thirtySecond: return String(localized: "32nd")
        }
    }

    static func from(musicXMLType: String) -> NoteValue? {
        NoteValue(rawValue: musicXMLType.lowercased())
    }
}

/// What the ♯ ♭ ♮ buttons set.
enum AccidentalChoice: String, CaseIterable {
    case sharp, flat, natural
    /// No accidental sign: the note takes the key signature.
    case none
}

/// A bar whose voice-1 durations do not add up to its time signature.
struct BarCheckIssue: Equatable {
    var measureIndex: Int
    /// The printed measure number.
    var measureNumber: String
    var beats: Int
    var beatType: Int
    /// Beats the bar should hold, in units of the time signature's beat type (= `beats`).
    var expectedBeats: Double
    /// Beats the voice-1 notes actually add up to, in the same units.
    var actualBeats: Double
}

enum ScoreEditError: Error, LocalizedError, Equatable {
    case noPart
    case noMeasure(Int)
    case noNote(NoteAddress)
    case notPitched
    case noNextNote
    case noNoteType

    var errorDescription: String? {
        switch self {
        case .noPart:
            return String(localized: "This file has no part to edit.")
        case .noMeasure:
            return String(localized: "That bar is not in the part any more.")
        case .noNote:
            return String(localized: "That note is not in the part any more. Tap a note first.")
        case .notPitched:
            return String(localized: "This only works on a note, not a rest.")
        case .noNextNote:
            return String(localized: "There is no next note to tie to.")
        case .noNoteType:
            return String(localized: "Give this note a length first (whole, half, quarter…).")
        }
    }
}

/// An exact length in quarter notes (numerator / denominator), always reduced, denominator > 0.
struct BeatFraction: Equatable {
    private(set) var numerator: Int
    private(set) var denominator: Int

    init(_ numerator: Int, _ denominator: Int) {
        var n = numerator
        var d = denominator == 0 ? 1 : denominator
        if d < 0 {
            n = -n
            d = -d
        }
        let g = BeatFraction.gcd(abs(n), d)
        if g > 1 {
            n /= g
            d /= g
        }
        self.numerator = n
        self.denominator = d
    }

    var doubleValue: Double { Double(numerator) / Double(denominator) }
    var isInteger: Bool { denominator == 1 }

    static func * (lhs: BeatFraction, rhs: BeatFraction) -> BeatFraction {
        BeatFraction(lhs.numerator * rhs.numerator, lhs.denominator * rhs.denominator)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return x == 0 ? 1 : x
    }

    /// Augmentation-dot factor as a fraction: 0 dots = 1, 1 dot = 3/2, 2 dots = 7/4 ...
    static func dotFactor(dots: Int) -> BeatFraction {
        var numerator = 1
        var denominator = 1
        var remaining = dots
        while remaining > 0 {
            // factor = factor + 1/2^k
            numerator = numerator * 2 + 1
            denominator *= 2
            remaining -= 1
        }
        return BeatFraction(numerator, denominator)
    }
}

enum ScoreEditing {

    // MARK: Lookup

    static func firstPart(in tree: MusicXMLTree) -> MusicXMLElement? {
        guard tree.root.name == "score-partwise" else { return nil }
        return tree.root.firstChild(named: "part")
    }

    static func measures(in tree: MusicXMLTree) -> [MusicXMLElement] {
        guard let part = firstPart(in: tree) else { return [] }
        return part.children(named: "measure")
    }

    /// Printed measure numbers of the first part, in order.
    static func measureNumbers(in tree: MusicXMLTree) -> [String] {
        measures(in: tree).enumerated().map { pair in
            pair.element.attribute("number") ?? String(pair.offset + 1)
        }
    }

    /// `true` for a voice-1 note that is neither a grace note nor a chord member.
    static func isAddressable(_ note: MusicXMLElement) -> Bool {
        guard note.name == "note" else { return false }
        if note.firstChild(named: "grace") != nil { return false }
        if note.firstChild(named: "chord") != nil { return false }
        if let voice = note.firstChild(named: "voice") {
            let v = voice.text
            return v.isEmpty || v == "1"
        }
        return true
    }

    /// The editable notes of a measure, in order.
    static func addressableNotes(in measure: MusicXMLElement) -> [MusicXMLElement] {
        measure.children(named: "note").filter { isAddressable($0) }
    }

    static func measure(at index: Int, in tree: MusicXMLTree) -> MusicXMLElement? {
        let all = measures(in: tree)
        guard index >= 0, index < all.count else { return nil }
        return all[index]
    }

    static func note(at address: NoteAddress, in tree: MusicXMLTree) -> MusicXMLElement? {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { return nil }
        let notes = addressableNotes(in: bar)
        guard address.noteIndex >= 0, address.noteIndex < notes.count else { return nil }
        return notes[address.noteIndex]
    }

    /// Number of editable notes per measure.
    static func noteCounts(in tree: MusicXMLTree) -> [Int] {
        measures(in: tree).map { addressableNotes(in: $0).count }
    }

    /// Index of the address's measure (clamped) for display, and whether the address still exists.
    static func isValid(_ address: NoteAddress, in tree: MusicXMLTree) -> Bool {
        note(at: address, in: tree) != nil
    }

    /// Chord members that follow a note (`<chord/>` notes right after it).
    static func chordMembers(of note: MusicXMLElement, in measure: MusicXMLElement) -> [MusicXMLElement] {
        guard let start = measure.index(ofChild: note) else { return [] }
        var members: [MusicXMLElement] = []
        var index = start + 1
        while index < measure.children.count {
            guard let element = measure.children[index].element else {
                index += 1
                continue
            }
            if element.name == "note", element.firstChild(named: "chord") != nil {
                members.append(element)
                index += 1
            } else {
                break
            }
        }
        return members
    }

    // MARK: Attributes in effect

    /// `<divisions>` in effect at a measure (the last one written up to and including it; 1 when none).
    static func divisions(atMeasure index: Int, in tree: MusicXMLTree) -> Int {
        var current = 1
        for (i, measure) in measures(in: tree).enumerated() where i <= index {
            for attributes in measure.children(named: "attributes") {
                if let d = attributes.firstChild(named: "divisions"), let value = Int(d.text), value > 0 {
                    current = value
                }
            }
        }
        return current
    }

    /// Key signature (`<fifths>`) in effect at a measure (0 when none).
    static func keyFifths(atMeasure index: Int, in tree: MusicXMLTree) -> Int {
        var current = 0
        for (i, measure) in measures(in: tree).enumerated() where i <= index {
            for attributes in measure.children(named: "attributes") {
                if let key = attributes.firstChild(named: "key"), let f = key.firstChild(named: "fifths"), let value = Int(f.text) {
                    current = value
                }
            }
        }
        return current
    }

    /// Clef (sign, line) in effect at a measure.
    static func clef(atMeasure index: Int, in tree: MusicXMLTree) -> (sign: String, line: Int?)? {
        var current: (sign: String, line: Int?)? = nil
        for (i, measure) in measures(in: tree).enumerated() where i <= index {
            for attributes in measure.children(named: "attributes") {
                for clef in attributes.children(named: "clef") {
                    if let sign = clef.firstChild(named: "sign") {
                        let line = clef.firstChild(named: "line").flatMap { Int($0.text) }
                        current = (sign: sign.text, line: line)
                    }
                }
            }
        }
        return current
    }

    /// Alteration the key signature gives a step: +1, -1 or 0.
    static func keyAlteration(step: String, fifths: Int) -> Int {
        let sharps = ["F", "C", "G", "D", "A", "E", "B"]
        let flats = ["B", "E", "A", "D", "G", "C", "F"]
        let upper = step.uppercased()
        if fifths > 0 {
            return sharps.prefix(min(7, fifths)).contains(upper) ? 1 : 0
        }
        if fifths < 0 {
            return flats.prefix(min(7, -fifths)).contains(upper) ? -1 : 0
        }
        return 0
    }

    // MARK: Pitch

    struct Spelling: Equatable {
        var step: String
        var alter: Int
        var octave: Int

        var midi: Int? { PitchMath.midi(step: step, alter: alter, octave: octave) }
    }

    /// Spelling of a MIDI number with sharps or flats (never B♯ / C♭ / E♯ / F♭).
    static func spelling(midi: Int, preferFlats: Bool) -> Spelling {
        let clamped = max(0, min(127, midi))
        let pitchClass = clamped % 12
        let octave = clamped / 12 - 1
        let sharps: [(String, Int)] = [("C", 0), ("C", 1), ("D", 0), ("D", 1), ("E", 0), ("F", 0), ("F", 1), ("G", 0), ("G", 1), ("A", 0), ("A", 1), ("B", 0)]
        let flats: [(String, Int)] = [("C", 0), ("D", -1), ("D", 0), ("E", -1), ("E", 0), ("F", 0), ("G", -1), ("G", 0), ("A", -1), ("A", 0), ("B", -1), ("B", 0)]
        let table = preferFlats ? flats : sharps
        let entry = table[pitchClass]
        return Spelling(step: entry.0, alter: entry.1, octave: octave)
    }

    static func spelling(of note: MusicXMLElement) -> Spelling? {
        guard let pitch = note.firstChild(named: "pitch"),
              let step = pitch.firstChild(named: "step")?.text, !step.isEmpty,
              let octaveText = pitch.firstChild(named: "octave")?.text, let octave = Int(octaveText) else { return nil }
        var alter = 0
        if let alterText = pitch.firstChild(named: "alter")?.text, let value = Double(alterText) {
            alter = Int(value.rounded())
        }
        return Spelling(step: step.uppercased(), alter: alter, octave: octave)
    }

    /// Writes a spelling into the note's `<pitch>` and updates `<accidental>` against the key signature.
    static func write(_ spelling: Spelling, to note: MusicXMLElement, keyFifths: Int) {
        let pitch: MusicXMLElement
        if let existing = note.firstChild(named: "pitch") {
            pitch = existing
        } else {
            pitch = MusicXMLElement(name: "pitch")
            insertOrdered(pitch, into: note, order: noteChildOrder)
        }
        setChildText(of: pitch, named: "step", to: spelling.step, order: pitchChildOrder)
        if spelling.alter == 0 {
            pitch.removeChildren(named: "alter")
        } else {
            setChildText(of: pitch, named: "alter", to: String(spelling.alter), order: pitchChildOrder)
        }
        setChildText(of: pitch, named: "octave", to: String(spelling.octave), order: pitchChildOrder)

        let inKey = keyAlteration(step: spelling.step, fifths: keyFifths)
        if spelling.alter == inKey {
            note.removeChildren(named: "accidental")
        } else if let name = accidentalName(alter: spelling.alter) {
            setChildText(of: note, named: "accidental", to: name, order: noteChildOrder)
        } else {
            note.removeChildren(named: "accidental")
        }
    }

    static func accidentalName(alter: Int) -> String? {
        switch alter {
        case 2: return "double-sharp"
        case 1: return "sharp"
        case 0: return "natural"
        case -1: return "flat"
        case -2: return "flat-flat"
        default: return nil
        }
    }

    /// Moves a note up or down by `semitones` (±1 from the palette) and respells it.
    static func transpose(_ address: NoteAddress, by semitones: Int, in tree: MusicXMLTree) throws {
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        guard let current = spelling(of: note), let midi = current.midi else { throw ScoreEditError.notPitched }
        let fifths = keyFifths(atMeasure: address.measureIndex, in: tree)
        let preferFlats: Bool
        if fifths < 0 {
            preferFlats = true
        } else if fifths > 0 {
            preferFlats = false
        } else {
            preferFlats = semitones < 0
        }
        let target = spelling(midi: midi + semitones, preferFlats: preferFlats)
        write(target, to: note, keyFifths: fifths)
    }

    /// Sets the accidental sign (and the matching `<alter>`).
    static func setAccidental(_ address: NoteAddress, _ choice: AccidentalChoice, in tree: MusicXMLTree) throws {
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        guard var current = spelling(of: note) else { throw ScoreEditError.notPitched }
        let fifths = keyFifths(atMeasure: address.measureIndex, in: tree)
        switch choice {
        case .sharp: current.alter = 1
        case .flat: current.alter = -1
        case .natural: current.alter = 0
        case .none: current.alter = keyAlteration(step: current.step, fifths: fifths)
        }
        write(current, to: note, keyFifths: fifths)
        // The explicit sign the player asked for, even when the key already implies it.
        switch choice {
        case .sharp, .flat, .natural:
            if let name = accidentalName(alter: current.alter) {
                setChildText(of: note, named: "accidental", to: name, order: noteChildOrder)
            }
        case .none:
            note.removeChildren(named: "accidental")
        }
    }

    // MARK: Duration

    /// Sets the note value (keeps dots and tuplet marks) and recomputes `<duration>`.
    static func setDuration(_ address: NoteAddress, _ value: NoteValue, in tree: MusicXMLTree) throws {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { throw ScoreEditError.noMeasure(address.measureIndex) }
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        if let rest = note.firstChild(named: "rest") {
            rest.setAttribute("measure", to: nil)
        }
        let targets: [MusicXMLElement] = [note] + chordMembers(of: note, in: bar)
        for target in targets {
            setChildText(of: target, named: "type", to: value.musicXMLType, order: noteChildOrder)
        }
        try recomputeDuration(of: targets, measureIndex: address.measureIndex, in: tree)
        stripBeams(in: bar)
    }

    /// Adds a dot when the note has none, otherwise removes all dots; recomputes `<duration>`.
    static func toggleDot(_ address: NoteAddress, in tree: MusicXMLTree) throws {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { throw ScoreEditError.noMeasure(address.measureIndex) }
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        guard note.firstChild(named: "type") != nil else { throw ScoreEditError.noNoteType }
        let hadDots = !note.children(named: "dot").isEmpty
        let targets: [MusicXMLElement] = [note] + chordMembers(of: note, in: bar)
        for target in targets {
            target.removeChildren(named: "dot")
            if !hadDots {
                insertOrdered(MusicXMLElement(name: "dot"), into: target, order: noteChildOrder)
            }
        }
        try recomputeDuration(of: targets, measureIndex: address.measureIndex, in: tree)
        stripBeams(in: bar)
    }

    /// Length of a note in quarter notes from its `<type>`, dots and tuplet; `nil` without a usable type.
    static func writtenLength(of note: MusicXMLElement) -> BeatFraction? {
        guard let typeText = note.firstChild(named: "type")?.text, let value = NoteValue.from(musicXMLType: typeText) else {
            return nil
        }
        var length = value.quarters * BeatFraction.dotFactor(dots: note.children(named: "dot").count)
        if let mod = note.firstChild(named: "time-modification"),
           let actual = mod.firstChild(named: "actual-notes").flatMap({ Int($0.text) }), actual > 0,
           let normal = mod.firstChild(named: "normal-notes").flatMap({ Int($0.text) }), normal > 0 {
            length = length * BeatFraction(normal, actual)
        }
        return length
    }

    /// Rewrites `<duration>` of the notes from their written length, scaling the part's divisions when needed.
    private static func recomputeDuration(of notes: [MusicXMLElement], measureIndex: Int, in tree: MusicXMLTree) throws {
        guard let first = notes.first, let length = writtenLength(of: first) else { throw ScoreEditError.noNoteType }
        var div = ScoreEditing.divisions(atMeasure: measureIndex, in: tree)
        // duration = divisions * numerator / denominator must be an integer.
        let g = BeatFraction.gcd(div * length.numerator, length.denominator)
        let factor = length.denominator / g
        if factor > 1 {
            scaleDurations(by: factor, in: tree)
            div *= factor
        }
        let duration = div * length.numerator / length.denominator
        for note in notes {
            setChildText(of: note, named: "duration", to: String(max(1, duration)), order: noteChildOrder)
        }
    }

    /// Multiplies every `<divisions>` and `<duration>` of the first part by `factor`. A part that
    /// never wrote `<divisions>` (so 1 was in force) gets `<attributes><divisions>` in its first bar.
    static func scaleDurations(by factor: Int, in tree: MusicXMLTree) {
        guard factor > 1, let part = firstPart(in: tree) else { return }
        var sawDivisions = false
        for element in part.descendants where element.name == "divisions" || element.name == "duration" {
            if element.name == "divisions" { sawDivisions = true }
            if let value = Int(element.text) {
                element.setText(String(value * factor))
            } else if let value = Double(element.text) {
                element.setText(String(Int((value * Double(factor)).rounded())))
            }
        }
        if !sawDivisions, let firstMeasure = part.firstChild(named: "measure") {
            let divisionsElement = MusicXMLElement(name: "divisions", text: String(factor))
            if let attributes = firstMeasure.firstChild(named: "attributes") {
                attributes.insert(divisionsElement, at: 0)
            } else {
                let attributes = MusicXMLElement(name: "attributes", attributes: [], children: [.element(divisionsElement)])
                firstMeasure.insert(attributes, at: 0)
            }
        }
    }

    /// Removes `<beam>` marks from every note of the measure (notes are drawn with flags instead).
    static func stripBeams(in measure: MusicXMLElement) {
        for note in measure.children(named: "note") {
            note.removeChildren(named: "beam")
        }
    }

    // MARK: Note ↔ rest

    /// Turns a note into a rest of the same length, or a rest into a note (pitch of the previous note, else the clef's middle line).
    static func toggleRest(_ address: NoteAddress, in tree: MusicXMLTree) throws {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { throw ScoreEditError.noMeasure(address.measureIndex) }
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        if note.firstChild(named: "rest") != nil {
            try makeNote(note, address: address, in: tree)
        } else {
            makeRest(note, in: bar, tree: tree)
        }
        stripBeams(in: bar)
    }

    private static func makeRest(_ note: MusicXMLElement, in measure: MusicXMLElement, tree: MusicXMLTree) {
        untieFromPrevious(note, in: tree)
        untieFromNext(note, in: tree)
        for member in chordMembers(of: note, in: measure) {
            measure.remove(member)
        }
        note.removeChildren(named: "pitch")
        note.removeChildren(named: "unpitched")
        note.removeChildren(named: "accidental")
        note.removeChildren(named: "tie")
        note.removeChildren(named: "stem")
        note.removeChildren(named: "notehead")
        note.removeChildren(named: "notehead-text")
        removeTiedNotations(from: note)
        if note.firstChild(named: "rest") == nil {
            insertOrdered(MusicXMLElement(name: "rest"), into: note, order: noteChildOrder)
        }
    }

    private static func makeNote(_ note: MusicXMLElement, address: NoteAddress, in tree: MusicXMLTree) throws {
        note.removeChildren(named: "rest")
        let fifths = keyFifths(atMeasure: address.measureIndex, in: tree)
        let pitch = previousPitch(before: note, in: tree) ?? defaultPitch(forClef: clef(atMeasure: address.measureIndex, in: tree))
        write(pitch, to: note, keyFifths: fifths)
        if note.firstChild(named: "type") == nil {
            // A whole-bar rest has no <type>; pick the value that matches its length, else a quarter.
            let div = ScoreEditing.divisions(atMeasure: address.measureIndex, in: tree)
            let duration = note.firstChild(named: "duration").flatMap { Int($0.text) } ?? div
            let matching: NoteValue? = NoteValue.allCases.first { candidate in
                candidate.quarters.denominator == 1 && candidate.quarters.numerator * div == duration
            }
            let value: NoteValue = matching ?? NoteValue.quarter
            setChildText(of: note, named: "type", to: value.musicXMLType, order: noteChildOrder)
            note.removeChildren(named: "dot")
            try recomputeDuration(of: [note], measureIndex: address.measureIndex, in: tree)
        }
    }

    /// Pitch of the nearest pitched note before `note` in the first part.
    static func previousPitch(before note: MusicXMLElement, in tree: MusicXMLTree) -> Spelling? {
        var last: Spelling? = nil
        for measure in measures(in: tree) {
            for candidate in measure.children(named: "note") {
                if candidate === note { return last }
                if let s = spelling(of: candidate) { last = s }
            }
        }
        return last
    }

    /// The middle line of the clef (D3 in bass clef, B4 in treble, C4 alto, A3 tenor; B4 otherwise).
    static func defaultPitch(forClef clef: (sign: String, line: Int?)?) -> Spelling {
        guard let clef = clef else { return Spelling(step: "B", alter: 0, octave: 4) }
        switch clef.sign.uppercased() {
        case "F": return Spelling(step: "D", alter: 0, octave: 3)
        case "C":
            if clef.line == 4 { return Spelling(step: "A", alter: 0, octave: 3) }
            return Spelling(step: "C", alter: 0, octave: 4)
        default: return Spelling(step: "B", alter: 0, octave: 4)
        }
    }

    // MARK: Delete / insert

    /// Removes the note (with its chord members) and clears ties that pointed at it.
    static func deleteNote(_ address: NoteAddress, in tree: MusicXMLTree) throws {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { throw ScoreEditError.noMeasure(address.measureIndex) }
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        untieFromPrevious(note, in: tree)
        untieFromNext(note, in: tree)
        for member in chordMembers(of: note, in: bar) {
            bar.remove(member)
        }
        bar.remove(note)
        stripBeams(in: bar)
    }

    /// Inserts a copy of the note right after it (same pitch and length, no ties, beams or lyrics). Returns the copy's address.
    @discardableResult
    static func insertNoteAfter(_ address: NoteAddress, in tree: MusicXMLTree) throws -> NoteAddress {
        guard let bar = ScoreEditing.measure(at: address.measureIndex, in: tree) else { throw ScoreEditError.noMeasure(address.measureIndex) }
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        let copy = note.deepCopy()
        copy.removeChildren(named: "tie")
        copy.removeChildren(named: "notations")
        copy.removeChildren(named: "beam")
        copy.removeChildren(named: "lyric")
        copy.setAttribute("id", to: nil)
        if let rest = copy.firstChild(named: "rest") {
            rest.setAttribute("measure", to: nil)
        }
        let anchor: MusicXMLElement = chordMembers(of: note, in: bar).last ?? note
        bar.insert(copy, after: anchor)
        stripBeams(in: bar)
        return NoteAddress(measureIndex: address.measureIndex, noteIndex: address.noteIndex + 1)
    }

    // MARK: Ties

    /// The editable note after `address` (same measure, else the next measure that has one).
    static func nextAddress(after address: NoteAddress, in tree: MusicXMLTree) -> NoteAddress? {
        let all = measures(in: tree)
        guard address.measureIndex >= 0, address.measureIndex < all.count else { return nil }
        let count = addressableNotes(in: all[address.measureIndex]).count
        if address.noteIndex + 1 < count {
            return NoteAddress(measureIndex: address.measureIndex, noteIndex: address.noteIndex + 1)
        }
        var index = address.measureIndex + 1
        while index < all.count {
            if !addressableNotes(in: all[index]).isEmpty {
                return NoteAddress(measureIndex: index, noteIndex: 0)
            }
            index += 1
        }
        return nil
    }

    static func hasTie(_ note: MusicXMLElement, type: String) -> Bool {
        note.children(named: "tie").contains { $0.attribute("type") == type }
    }

    /// Ties the note to the next one, or removes that tie when it is there.
    static func toggleTie(_ address: NoteAddress, in tree: MusicXMLTree) throws {
        guard let note = ScoreEditing.note(at: address, in: tree) else { throw ScoreEditError.noNote(address) }
        guard note.firstChild(named: "pitch") != nil else { throw ScoreEditError.notPitched }
        guard let following = ScoreEditing.nextAddress(after: address, in: tree),
              let next = ScoreEditing.note(at: following, in: tree) else {
            throw ScoreEditError.noNextNote
        }
        guard next.firstChild(named: "pitch") != nil else { throw ScoreEditError.noNextNote }
        if hasTie(note, type: "start") {
            removeTie(from: note, type: "start")
            removeTie(from: next, type: "stop")
        } else {
            addTie(to: note, type: "start")
            addTie(to: next, type: "stop")
        }
    }

    static func addTie(to note: MusicXMLElement, type: String) {
        if !hasTie(note, type: type) {
            let tie = MusicXMLElement(name: "tie", attributes: [MusicXMLAttribute(name: "type", value: type)])
            insertOrdered(tie, into: note, order: noteChildOrder)
        }
        let notations: MusicXMLElement
        if let existing = note.firstChild(named: "notations") {
            notations = existing
        } else {
            notations = MusicXMLElement(name: "notations")
            insertOrdered(notations, into: note, order: noteChildOrder)
        }
        let alreadyThere = notations.children(named: "tied").contains { $0.attribute("type") == type }
        if !alreadyThere {
            notations.append(MusicXMLElement(name: "tied", attributes: [MusicXMLAttribute(name: "type", value: type)]))
        }
    }

    static func removeTie(from note: MusicXMLElement, type: String) {
        note.children = note.children.filter { child in
            if case .element(let e) = child, e.name == "tie", e.attribute("type") == type { return false }
            return true
        }
        if let notations = note.firstChild(named: "notations") {
            notations.children = notations.children.filter { child in
                if case .element(let e) = child, e.name == "tied", e.attribute("type") == type { return false }
                return true
            }
            if notations.childElements.isEmpty {
                note.remove(notations)
            }
        }
    }

    private static func removeTiedNotations(from note: MusicXMLElement) {
        removeTie(from: note, type: "start")
        removeTie(from: note, type: "stop")
        removeTie(from: note, type: "continue")
    }

    /// If the previous editable note is tied into this one, removes its tie start.
    private static func untieFromPrevious(_ note: MusicXMLElement, in tree: MusicXMLTree) {
        guard hasTie(note, type: "stop") else { return }
        var previous: MusicXMLElement? = nil
        outer: for measure in measures(in: tree) {
            for candidate in addressableNotes(in: measure) {
                if candidate === note { break outer }
                previous = candidate
            }
        }
        if let previous = previous, hasTie(previous, type: "start") {
            removeTie(from: previous, type: "start")
        }
    }

    /// If this note is tied into the next editable note, removes that note's tie stop.
    private static func untieFromNext(_ note: MusicXMLElement, in tree: MusicXMLTree) {
        guard hasTie(note, type: "start") else { return }
        var found = false
        for measure in measures(in: tree) {
            for candidate in addressableNotes(in: measure) {
                if found {
                    if hasTie(candidate, type: "stop") {
                        removeTie(from: candidate, type: "stop")
                    }
                    return
                }
                if candidate === note { found = true }
            }
        }
    }

    // MARK: Bar check

    /// One measure's length against its time signature (quarter notes), before the pickup rules.
    private struct MeasureLength {
        var index: Int
        var number: String
        var beats: Int
        var beatType: Int
        var expectedQuarters: Double
        var actualQuarters: Double
        /// `implicit="yes"` or numbered "0": the file itself says this is a pickup bar.
        var isMarkedPickup: Bool

        var isShort: Bool { actualQuarters < expectedQuarters - 1e-6 }
        var shortfall: Double { expectedQuarters - actualQuarters }
    }

    /// Bars whose voice-1 notes do not add up to the time signature in force.
    ///
    /// Pickup rule: a short FIRST bar is accepted when the file marks it as a pickup (`implicit="yes"`
    /// or number "0"), or when the LAST bar is short by exactly the missing amount (the classic
    /// pickup + completing bar). A short last bar that completes an accepted pickup is accepted too.
    /// Any other short or long bar is reported — including an unmarked short first bar, which in a
    /// scan is far more often a misread note than a pickup.
    static func barCheck(in tree: MusicXMLTree) -> [BarCheckIssue] {
        let all = measures(in: tree)
        var divisions = 1
        var beats: Int? = nil
        var beatType: Int? = nil
        var lengths: [MeasureLength] = []

        for (index, measure) in all.enumerated() {
            var actualQuarters: Double = 0
            for child in measure.childElements {
                switch child.name {
                case "attributes":
                    if let d = child.firstChild(named: "divisions"), let value = Int(d.text), value > 0 {
                        divisions = value
                    }
                    if let time = child.firstChild(named: "time"),
                       let b = time.firstChild(named: "beats").flatMap({ parseBeats($0.text) }), b > 0,
                       let t = time.firstChild(named: "beat-type").flatMap({ Int($0.text) }), t > 0 {
                        beats = b
                        beatType = t
                    }
                case "note":
                    guard isAddressable(child) else { continue }
                    actualQuarters += quarters(of: child, divisions: divisions)
                default:
                    break
                }
            }
            guard let b = beats, let t = beatType else { continue }
            let number: String = measure.attribute("number") ?? String(index + 1)
            let marked: Bool = (measure.attribute("implicit") == "yes") || number == "0"
            lengths.append(MeasureLength(index: index,
                                         number: number,
                                         beats: b,
                                         beatType: t,
                                         expectedQuarters: Double(b) * 4.0 / Double(t),
                                         actualQuarters: actualQuarters,
                                         isMarkedPickup: marked))
        }

        let epsilon = 1e-6
        let lastIndex = all.count - 1

        // Is the first bar an acceptable pickup? If so, how much is it short by?
        var pickupShortfall: Double? = nil
        if let first = lengths.first, first.index == 0, first.isShort {
            if first.isMarkedPickup {
                pickupShortfall = first.shortfall
            } else if lengths.count > 1, let last = lengths.last, last.index == lastIndex, last.isShort,
                      abs(last.actualQuarters - first.shortfall) <= epsilon {
                pickupShortfall = first.shortfall
            }
        }

        var issues: [BarCheckIssue] = []
        for item in lengths {
            if abs(item.actualQuarters - item.expectedQuarters) <= epsilon { continue }
            if item.index == 0, item.isShort, pickupShortfall != nil { continue }
            if item.index == lastIndex, item.index > 0, item.isShort, let shortfall = pickupShortfall,
               abs(item.actualQuarters - shortfall) <= epsilon {
                continue
            }
            let unit = Double(item.beatType) / 4.0
            issues.append(BarCheckIssue(measureIndex: item.index,
                                        measureNumber: item.number,
                                        beats: item.beats,
                                        beatType: item.beatType,
                                        expectedBeats: Double(item.beats),
                                        actualBeats: item.actualQuarters * unit))
        }
        return issues
    }

    /// Length of a note in quarter notes: `<duration>` / divisions, else from its written type.
    static func quarters(of note: MusicXMLElement, divisions: Int) -> Double {
        if let text = note.firstChild(named: "duration")?.text, let value = Double(text), divisions > 0 {
            return max(0, value / Double(divisions))
        }
        if let written = writtenLength(of: note) {
            return written.doubleValue
        }
        return 0
    }

    /// "4" or compound "3+2".
    static func parseBeats(_ text: String) -> Int? {
        let parts = text.split(separator: "+")
        guard !parts.isEmpty else { return nil }
        var total = 0
        for part in parts {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total += n
        }
        return total
    }

    // MARK: Child ordering (MusicXML element order inside <note> and <pitch>)

    static let noteChildOrder: [String] = [
        "grace", "cue", "chord", "pitch", "unpitched", "rest", "duration", "tie", "instrument", "footnote", "level",
        "voice", "type", "dot", "accidental", "time-modification", "stem", "notehead", "notehead-text", "staff",
        "beam", "notations", "lyric", "play", "listen",
    ]

    static let pitchChildOrder: [String] = ["step", "alter", "octave"]

    /// Inserts `child` before the first child whose name comes later in `order` (unknown names never trigger insertion).
    static func insertOrdered(_ child: MusicXMLElement, into parent: MusicXMLElement, order: [String]) {
        guard let rank = order.firstIndex(of: child.name) else {
            parent.append(child)
            return
        }
        for (index, node) in parent.children.enumerated() {
            guard case .element(let e) = node, let otherRank = order.firstIndex(of: e.name) else { continue }
            if otherRank > rank {
                parent.children.insert(.element(child), at: index)
                return
            }
        }
        parent.append(child)
    }

    /// Sets the text of the first child with that name, creating it in order when missing.
    static func setChildText(of parent: MusicXMLElement, named name: String, to text: String, order: [String]) {
        if let existing = parent.firstChild(named: name) {
            existing.setText(text)
        } else {
            insertOrdered(MusicXMLElement(name: name, text: text), into: parent, order: order)
        }
    }
}
