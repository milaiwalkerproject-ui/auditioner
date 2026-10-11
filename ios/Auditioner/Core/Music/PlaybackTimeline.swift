import Foundation

/// One sounding note (tied notes already merged), in quarter-note beats from the start of the music.
struct NoteEvent: Equatable {
    var midiSounding: UInt8
    var startBeat: Double
    var durationBeats: Double
    var measureIndex: Int

    var endBeat: Double { startBeat + durationBeats }
}

/// Everything the player and the MIDI writer need, derived from a `Score`.
struct PlaybackTimeline: Equatable {
    static let defaultBPM: Double = 80

    let events: [NoteEvent]
    /// Start beat of every measure, in order.
    let measureStartBeats: [Double]
    /// Printed measure numbers, same order as `measureStartBeats`.
    let measureNumbers: [String]
    let totalBeats: Double
    /// Tempo the music starts at: the document's preferred tempo, else the first written tempo, else 80.
    let initialBPM: Double
    /// Tempo changes as written in the part (unscaled).
    let writtenTempoChanges: [TempoChange]
    let timeSignatures: [TimeSignatureChange]
    /// Semitones added to the written pitch.
    let transposition: Int
    let keyFifths: Int

    // MARK: Building

    init(score: Score, transposition: Int, preferredBPM: Double? = nil) {
        var events: [NoteEvent] = []
        // Written MIDI of a note whose tie is still open → index into `events`.
        var openTies: [Int: Int] = [:]

        for (measureIndex, measure) in score.measures.enumerated() {
            for note in measure.notes {
                guard let written = note.midi else { continue }
                guard note.durationBeats > 0 else { continue }
                let soundingInt = max(0, min(127, written + transposition))
                let sounding = UInt8(soundingInt)

                if note.tieStop, let openIndex = openTies[written],
                   abs(events[openIndex].endBeat - note.startBeat) < 0.02 {
                    events[openIndex].durationBeats = (note.startBeat + note.durationBeats) - events[openIndex].startBeat
                    if !note.tieStart { openTies[written] = nil }
                    continue
                }

                events.append(NoteEvent(midiSounding: sounding,
                                        startBeat: note.startBeat,
                                        durationBeats: note.durationBeats,
                                        measureIndex: measureIndex))
                if note.tieStart {
                    openTies[written] = events.count - 1
                } else {
                    openTies[written] = nil
                }
            }
        }

        events.sort { a, b in
            if a.startBeat != b.startBeat { return a.startBeat < b.startBeat }
            return a.midiSounding < b.midiSounding
        }

        self.events = events
        self.measureStartBeats = score.measures.map { $0.startBeat }
        self.measureNumbers = score.measures.map { $0.number }
        self.totalBeats = max(score.totalBeats, events.last.map { $0.endBeat } ?? 0)
        if let preferred = preferredBPM, preferred > 0 {
            self.initialBPM = preferred
        } else if let first = score.firstTempoBPM, first > 0 {
            self.initialBPM = first
        } else {
            self.initialBPM = PlaybackTimeline.defaultBPM
        }
        self.writtenTempoChanges = score.tempoChanges
        self.timeSignatures = score.timeSignatures
        self.transposition = transposition
        self.keyFifths = score.keyFifths
    }

    /// Parses the document's MusicXML and applies the instrument's sounding transposition.
    init(document: ScoreDocument) throws {
        let score = try MusicXMLParser.parse(document.musicXML)
        let transposition = PlaybackTimeline.soundingTransposition(for: document.instrument, score: score)
        self.init(score: score, transposition: transposition, preferredBPM: document.preferredBPM)
    }

    /// Semitones to add to the written pitch so the playback sounds at pitch. The part's own
    /// `<transpose>` wins; otherwise only octave-transposing instruments are adjusted.
    static func soundingTransposition(for instrument: Instrument, score: Score) -> Int {
        if score.transposeChromatic != 0 || score.transposeOctaveChange != 0 {
            return score.transposeSemitones
        }
        switch instrument {
        case .doubleBass: return -12
        case .piccolo: return 12
        default: return 0
        }
    }

    // MARK: Queries

    var measureCount: Int { measureStartBeats.count }

    var firstTimeSignature: TimeSignatureChange? { timeSignatures.first }

    /// Index of the measure containing `beat` (clamped).
    func measureIndex(forBeat beat: Double) -> Int {
        guard !measureStartBeats.isEmpty else { return 0 }
        var index = 0
        for (i, start) in measureStartBeats.enumerated() where start <= beat + 1e-9 {
            index = i
        }
        return index
    }

    /// Start beat of a measure (clamped to the valid range).
    func startBeat(ofMeasure index: Int) -> Double {
        guard !measureStartBeats.isEmpty else { return 0 }
        let i = max(0, min(measureStartBeats.count - 1, index))
        return measureStartBeats[i]
    }

    /// End beat of a measure (the start of the next one, or the end of the music).
    func endBeat(ofMeasure index: Int) -> Double {
        guard !measureStartBeats.isEmpty else { return totalBeats }
        let i = max(0, min(measureStartBeats.count - 1, index))
        if i + 1 < measureStartBeats.count {
            return measureStartBeats[i + 1]
        }
        return totalBeats
    }

    /// Beat range covered by measures `from...to` (indices, clamped and ordered).
    func beatRange(fromMeasure from: Int, toMeasure to: Int) -> (start: Double, end: Double) {
        let lo = min(from, to)
        let hi = max(from, to)
        return (startBeat(ofMeasure: lo), endBeat(ofMeasure: hi))
    }

    /// Tempo map used for playback: starts at `baseBPM`; later written changes are scaled by the same factor.
    func tempoMap(baseBPM: Double) -> [TempoChange] {
        let reference: Double = writtenTempoChanges.first.map { $0.bpm } ?? initialBPM
        let scale: Double = (reference > 0) ? baseBPM / reference : 1
        var map: [TempoChange] = [TempoChange(beat: 0, bpm: baseBPM)]
        for change in writtenTempoChanges.sorted(by: { $0.beat < $1.beat }) where change.beat > 1e-9 {
            map.append(TempoChange(beat: change.beat, bpm: change.bpm * scale))
        }
        return map
    }

    /// Seconds from the start of the music to `beat`, when the music starts at `targetBPM`.
    func seconds(atBeat beat: Double, targetBPM: Double) -> Double {
        let map = tempoMap(baseBPM: targetBPM)
        var time: Double = 0
        var lastBeat: Double = 0
        var bpm: Double = map.first?.bpm ?? targetBPM
        for change in map.dropFirst() {
            if change.beat >= beat { break }
            if change.beat > lastBeat {
                time += (change.beat - lastBeat) * 60.0 / max(bpm, 1)
                lastBeat = change.beat
            }
            bpm = change.bpm
        }
        time += max(0, beat - lastBeat) * 60.0 / max(bpm, 1)
        return time
    }

    /// Count-in of `bars` bars of the first time signature (4/4 when none is written).
    func countIn(bars: Int) -> MIDIFileWriter.CountIn {
        let ts = firstTimeSignature ?? TimeSignatureChange(beat: 0, beats: 4, beatType: 4)
        let clicksPerBar = max(1, ts.beats)
        let spacing = ts.beatUnitQuarters
        let barCount = max(1, bars)
        return MIDIFileWriter.CountIn(clicksPerBar: clicksPerBar, clickSpacingBeats: spacing, bars: barCount)
    }
}
