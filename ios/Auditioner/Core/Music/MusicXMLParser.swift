import Foundation

enum MusicXMLParseError: Error, LocalizedError, Equatable {
    case malformed(String)
    case notPartwise
    case noPart

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return String(localized: "This MusicXML file couldn't be read (\(detail)).")
        case .notPartwise:
            return String(localized: "This MusicXML file is in the timewise layout, which the app can't play yet.")
        case .noPart:
            return String(localized: "This MusicXML file has no part with measures.")
        }
    }
}

/// Reads partwise MusicXML with Foundation's XMLParser.
/// Only the FIRST `<part>` and voice 1 are kept; grace notes are skipped; other voices still move
/// the cursor (so `<backup>` / `<forward>` keep measures the right length).
final class MusicXMLParser: NSObject, XMLParserDelegate {

    // MARK: Public API

    static func parse(_ xml: String) throws -> Score {
        try parse(data: Data(xml.utf8))
    }

    static func parse(data: Data) throws -> Score {
        let delegate = MusicXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if !ok {
            let detail = parser.parserError?.localizedDescription ?? delegate.firstErrorDescription ?? "unknown error"
            throw MusicXMLParseError.malformed(detail)
        }
        if delegate.sawTimewise && !delegate.isPartwise {
            throw MusicXMLParseError.notPartwise
        }
        guard !delegate.measures.isEmpty else {
            throw MusicXMLParseError.noPart
        }
        return delegate.makeScore()
    }

    // MARK: Parser state

    private var path: [String] = []
    private var text: String = ""
    private var firstErrorDescription: String?

    private var isPartwise = false
    private var sawTimewise = false
    private var partCount = 0
    private var insidePart = false
    private var isFirstPart: Bool { insidePart && partCount == 1 }

    // Score accumulators
    private var measures: [Measure] = []
    private var tempoChanges: [TempoChange] = []
    private var timeSignatures: [TimeSignatureChange] = []
    private var clefs: [ClefChange] = []
    private var divisions: Int = 1
    private var keyFifths: Int?
    private var transposeChromatic: Int = 0
    private var transposeOctaveChange: Int = 0
    private var partName: String?
    private var workTitle: String?

    // Measure state (positions in quarter notes relative to the measure start)
    private var insideMeasure = false
    private var measureNumber = ""
    private var pieceBeat: Double = 0
    private var cursorBeat: Double = 0
    private var measureMaxBeat: Double = 0
    private var measureNotes: [ScoreNote] = []
    private var lastNoteStartBeat: Double = 0

    // Note state
    private var insideNote = false
    private var noteStep: String?
    private var noteAlter: Int = 0
    private var noteOctave: Int?
    private var noteIsRest = false
    private var noteIsUnpitched = false
    private var noteIsChord = false
    private var noteIsGrace = false
    private var noteDurationDivisions: Int?
    private var noteVoice: String?
    private var noteType: String?
    private var noteDots: Int = 0
    private var noteTieStart = false
    private var noteTieStop = false
    private var noteTimeModActual: Int?
    private var noteTimeModNormal: Int?

    // Attribute / direction state
    private var pendingBeats: Int?
    private var pendingBeatType: Int?
    private var pendingClefSign: String?
    private var pendingClefLine: Int?
    private var pendingBackupForward: Int?
    private var metronomeBeatUnit: String?
    private var metronomeDots: Int = 0
    private var metronomePerMinute: Double?

    private func makeScore() -> Score {
        Score(measures: measures,
              tempoChanges: tempoChanges,
              divisions: divisions,
              keyFifths: keyFifths ?? 0,
              timeSignatures: timeSignatures,
              clefs: clefs,
              transposeChromatic: transposeChromatic,
              transposeOctaveChange: transposeOctaveChange,
              partName: partName,
              workTitle: workTitle)
    }

    private var currentBeat: Double { pieceBeat + cursorBeat }

    private func parent(at depth: Int = 1) -> String {
        let index = path.count - 1 - depth
        guard index >= 0, index < path.count else { return "" }
        return path[index]
    }

    private func recordTempo(bpm: Double, atBeat beat: Double) {
        guard bpm > 0, bpm.isFinite else { return }
        if let last = tempoChanges.last, abs(last.beat - beat) < 1e-6 {
            tempoChanges[tempoChanges.count - 1] = TempoChange(beat: beat, bpm: bpm)
        } else {
            tempoChanges.append(TempoChange(beat: beat, bpm: bpm))
        }
    }

    private static func leadingNumber(in string: String) -> Double? {
        let scanner = Scanner(string: string)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "~≈=cCaA."))
        if let value: Double = scanner.scanDouble() {
            return value
        }
        return nil
    }

    private static func parseBeats(_ string: String) -> Int? {
        // "4" or compound "3+2".
        let parts = string.split(separator: "+")
        var total = 0
        for part in parts {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total += n
        }
        return parts.isEmpty ? nil : total
    }

    // MARK: Element handlers

    private func startMeasure(attributes: [String: String]) {
        insideMeasure = true
        measureNumber = attributes["number"] ?? String(measures.count + 1)
        cursorBeat = 0
        measureMaxBeat = 0
        measureNotes = []
        lastNoteStartBeat = 0
    }

    private func endMeasure() {
        var length = measureMaxBeat
        if length <= 0 {
            let ts = timeSignatures.last
            length = ts?.barLengthBeats ?? 0
        }
        measures.append(Measure(number: measureNumber, startBeat: pieceBeat, lengthBeats: length, notes: measureNotes))
        pieceBeat += length
        insideMeasure = false
        measureNotes = []
    }

    private func startNote() {
        insideNote = true
        noteStep = nil
        noteAlter = 0
        noteOctave = nil
        noteIsRest = false
        noteIsUnpitched = false
        noteIsChord = false
        noteIsGrace = false
        noteDurationDivisions = nil
        noteVoice = nil
        noteType = nil
        noteDots = 0
        noteTieStart = false
        noteTieStop = false
        noteTimeModActual = nil
        noteTimeModNormal = nil
    }

    private func endNote() {
        insideNote = false
        if noteIsGrace { return }

        var durationBeats: Double = 0
        if let d = noteDurationDivisions, divisions > 0 {
            durationBeats = Double(d) / Double(divisions)
        } else if let type = noteType, let quarters = PitchMath.quarters(forNoteType: type) {
            var value = quarters * PitchMath.dotFactor(dots: noteDots)
            if let actual = noteTimeModActual, let normal = noteTimeModNormal, actual > 0 {
                value = value * Double(normal) / Double(actual)
            }
            durationBeats = value
        }
        if durationBeats < 0 { durationBeats = 0 }

        let startInMeasure: Double = noteIsChord ? lastNoteStartBeat : cursorBeat
        let isVoiceOne = (noteVoice == nil || noteVoice == "1")

        if isVoiceOne {
            var midi: Int? = nil
            if !noteIsRest && !noteIsUnpitched, let step = noteStep, let octave = noteOctave {
                midi = PitchMath.midi(step: step, alter: noteAlter, octave: octave)
            }
            let note = ScoreNote(midi: midi,
                                 startBeat: pieceBeat + startInMeasure,
                                 durationBeats: durationBeats,
                                 tieStart: noteTieStart,
                                 tieStop: noteTieStop,
                                 isChordMember: noteIsChord)
            measureNotes.append(note)
        }

        if noteIsChord {
            measureMaxBeat = max(measureMaxBeat, startInMeasure + durationBeats)
        } else {
            lastNoteStartBeat = cursorBeat
            cursorBeat += durationBeats
            measureMaxBeat = max(measureMaxBeat, cursorBeat)
        }
    }

    private func endMetronome() {
        guard let perMinute = metronomePerMinute, let unit = metronomeBeatUnit,
              let quarters = PitchMath.quarters(forNoteType: unit) else {
            metronomeBeatUnit = nil
            metronomePerMinute = nil
            metronomeDots = 0
            return
        }
        let bpm = perMinute * quarters * PitchMath.dotFactor(dots: metronomeDots)
        recordTempo(bpm: bpm, atBeat: currentBeat)
        metronomeBeatUnit = nil
        metronomePerMinute = nil
        metronomeDots = 0
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        text = ""

        switch elementName {
        case "score-partwise":
            isPartwise = true
        case "score-timewise":
            sawTimewise = true
        case "part":
            partCount += 1
            insidePart = true
        default:
            break
        }

        guard isFirstPart else { return }

        switch elementName {
        case "measure":
            startMeasure(attributes: attributeDict)
        case "note":
            startNote()
        case "rest":
            if insideNote { noteIsRest = true }
        case "unpitched":
            if insideNote { noteIsUnpitched = true }
        case "chord":
            if insideNote { noteIsChord = true }
        case "grace":
            if insideNote { noteIsGrace = true }
        case "dot":
            if insideNote && parent() == "note" { noteDots += 1 }
        case "tie":
            if insideNote && parent() == "note" {
                let type = attributeDict["type"] ?? ""
                if type == "start" { noteTieStart = true }
                if type == "stop" { noteTieStop = true }
            }
        case "tied":
            // Notation-only tie (some OMR output writes only <tied>); treat like <tie>.
            if insideNote && parent() == "notations" {
                let type = attributeDict["type"] ?? ""
                if type == "start" { noteTieStart = true }
                if type == "stop" { noteTieStop = true }
            }
        case "sound":
            if let tempoText = attributeDict["tempo"], let bpm = Double(tempoText.trimmingCharacters(in: .whitespaces)) {
                recordTempo(bpm: bpm, atBeat: currentBeat)
            }
        case "metronome":
            metronomeBeatUnit = nil
            metronomeDots = 0
            metronomePerMinute = nil
        case "beat-unit-dot":
            if parent() == "metronome" { metronomeDots += 1 }
        case "time":
            pendingBeats = nil
            pendingBeatType = nil
        case "clef":
            pendingClefSign = nil
            pendingClefLine = nil
        case "backup", "forward":
            pendingBackupForward = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            text = ""
        }

        if elementName == "part" {
            insidePart = false
            return
        }

        // Header information outside <part>.
        if !insidePart {
            switch elementName {
            case "work-title":
                if workTitle == nil, parent() == "work" { workTitle = value }
            case "part-name":
                if partName == nil, parent() == "score-part" { partName = value }
            default:
                break
            }
            return
        }

        guard isFirstPart else { return }

        switch elementName {
        case "measure":
            if insideMeasure { endMeasure() }
        case "note":
            endNote()
        case "step":
            if insideNote && parent() == "pitch" { noteStep = value }
        case "alter":
            if insideNote && parent() == "pitch", let d = Double(value) { noteAlter = Int(d.rounded()) }
        case "octave":
            if insideNote && parent() == "pitch", let o = Int(value) { noteOctave = o }
        case "duration":
            let p = parent()
            if insideNote && p == "note" {
                if let d = Int(value) { noteDurationDivisions = d } else if let d = Double(value) { noteDurationDivisions = Int(d.rounded()) }
            } else if p == "backup" || p == "forward" {
                if let d = Int(value) { pendingBackupForward = d } else if let d = Double(value) { pendingBackupForward = Int(d.rounded()) }
            }
        case "voice":
            if insideNote && parent() == "note" { noteVoice = value }
        case "type":
            if insideNote && parent() == "note" { noteType = value }
        case "actual-notes":
            if insideNote && parent() == "time-modification", let n = Int(value) { noteTimeModActual = n }
        case "normal-notes":
            if insideNote && parent() == "time-modification", let n = Int(value) { noteTimeModNormal = n }
        case "backup":
            if let d = pendingBackupForward, divisions > 0 {
                cursorBeat -= Double(d) / Double(divisions)
                if cursorBeat < 0 { cursorBeat = 0 }
            }
            pendingBackupForward = nil
        case "forward":
            if let d = pendingBackupForward, divisions > 0 {
                cursorBeat += Double(d) / Double(divisions)
                measureMaxBeat = max(measureMaxBeat, cursorBeat)
            }
            pendingBackupForward = nil
        case "divisions":
            if parent() == "attributes", let d = Int(value), d > 0 { divisions = d }
        case "fifths":
            if parent() == "key", let f = Int(value) {
                if keyFifths == nil { keyFifths = f }
            }
        case "beats":
            if parent() == "time" { pendingBeats = MusicXMLParser.parseBeats(value) }
        case "beat-type":
            if parent() == "time" { pendingBeatType = Int(value) }
        case "time":
            if parent() == "attributes", let b = pendingBeats, let t = pendingBeatType, b > 0, t > 0 {
                timeSignatures.append(TimeSignatureChange(beat: currentBeat, beats: b, beatType: t))
            }
            pendingBeats = nil
            pendingBeatType = nil
        case "sign":
            if parent() == "clef" { pendingClefSign = value }
        case "line":
            if parent() == "clef" { pendingClefLine = Int(value) }
        case "clef":
            if parent() == "attributes", let sign = pendingClefSign, !sign.isEmpty {
                clefs.append(ClefChange(beat: currentBeat, sign: sign, line: pendingClefLine))
            }
            pendingClefSign = nil
            pendingClefLine = nil
        case "chromatic":
            if parent() == "transpose", let d = Double(value) { transposeChromatic = Int(d.rounded()) }
        case "octave-change":
            if parent() == "transpose", let n = Int(value) { transposeOctaveChange = n }
        case "beat-unit":
            if parent() == "metronome" { metronomeBeatUnit = value }
        case "per-minute":
            if parent() == "metronome" { metronomePerMinute = MusicXMLParser.leadingNumber(in: value) }
        case "metronome":
            endMetronome()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if firstErrorDescription == nil {
            firstErrorDescription = parseError.localizedDescription
        }
    }
}
