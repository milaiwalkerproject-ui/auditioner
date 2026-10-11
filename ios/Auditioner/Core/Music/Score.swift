import Foundation

// Plain value types describing a parsed part. All positions are in quarter-note beats
// counted from the start of the first measure (a pickup measure starts at beat 0 too).
// Pitches are *written* MIDI numbers; transposition is applied by PlaybackTimeline.

/// One note or rest of the first part, voice 1.
struct ScoreNote: Equatable {
    /// Written pitch as a MIDI note number ((octave + 1) * 12 + step + alter). `nil` for a rest.
    var midi: Int?
    /// Start in quarter notes from the start of the piece.
    var startBeat: Double
    /// Sounding length in quarter notes.
    var durationBeats: Double
    var tieStart: Bool
    var tieStop: Bool
    /// `true` when the note shares its start with the previous note (`<chord/>`).
    var isChordMember: Bool

    var isRest: Bool { midi == nil }

    init(midi: Int?, startBeat: Double, durationBeats: Double,
         tieStart: Bool = false, tieStop: Bool = false, isChordMember: Bool = false) {
        self.midi = midi
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.tieStart = tieStart
        self.tieStop = tieStop
        self.isChordMember = isChordMember
    }
}

struct Measure: Equatable {
    /// The `number` attribute as printed (a string: parts use "0", "12a" etc.).
    var number: String
    /// Start in quarter notes from the start of the piece.
    var startBeat: Double
    /// Length in quarter notes (the content actually present in the measure).
    var lengthBeats: Double
    var notes: [ScoreNote]

    var endBeat: Double { startBeat + lengthBeats }
}

/// A tempo in quarter-note beats per minute that applies from `beat` onwards.
struct TempoChange: Equatable {
    var beat: Double
    var bpm: Double
}

/// A time signature that applies from `beat` onwards.
struct TimeSignatureChange: Equatable {
    var beat: Double
    var beats: Int
    var beatType: Int

    /// Length of one bar in quarter notes.
    var barLengthBeats: Double {
        guard beatType > 0 else { return 4 }
        return Double(beats) * 4.0 / Double(beatType)
    }

    /// Length of one counted beat (one "click") in quarter notes.
    var beatUnitQuarters: Double {
        guard beatType > 0 else { return 1 }
        return 4.0 / Double(beatType)
    }
}

/// A clef as written in the first part.
struct ClefChange: Equatable {
    var beat: Double
    var sign: String
    var line: Int?
}

/// The first part of a partwise MusicXML file, voice 1 only.
struct Score: Equatable {
    var measures: [Measure]
    var tempoChanges: [TempoChange]
    /// The last `<divisions>` value seen (divisions of a quarter note).
    var divisions: Int
    var keyFifths: Int
    var timeSignatures: [TimeSignatureChange]
    var clefs: [ClefChange]
    /// `<transpose><chromatic>` of the part (0 when absent): semitones to add to written pitch to get sounding pitch.
    var transposeChromatic: Int
    /// `<transpose><octave-change>` of the part (0 when absent).
    var transposeOctaveChange: Int
    var partName: String?
    var workTitle: String?

    init(measures: [Measure] = [], tempoChanges: [TempoChange] = [], divisions: Int = 1, keyFifths: Int = 0,
         timeSignatures: [TimeSignatureChange] = [], clefs: [ClefChange] = [],
         transposeChromatic: Int = 0, transposeOctaveChange: Int = 0, partName: String? = nil, workTitle: String? = nil) {
        self.measures = measures
        self.tempoChanges = tempoChanges
        self.divisions = divisions
        self.keyFifths = keyFifths
        self.timeSignatures = timeSignatures
        self.clefs = clefs
        self.transposeChromatic = transposeChromatic
        self.transposeOctaveChange = transposeOctaveChange
        self.partName = partName
        self.workTitle = workTitle
    }

    /// All notes and rests of voice 1 in order.
    var notes: [ScoreNote] {
        measures.flatMap { $0.notes }
    }

    /// Total transposition written in the part, in semitones (chromatic + 12 * octave-change).
    var transposeSemitones: Int {
        transposeChromatic + 12 * transposeOctaveChange
    }

    /// End of the last measure in quarter notes.
    var totalBeats: Double {
        measures.last.map { $0.endBeat } ?? 0
    }

    /// The first tempo written in the part, if any.
    var firstTempoBPM: Double? {
        tempoChanges.first?.bpm
    }

    /// The time signature in force at `beat` (the first one when none precedes it).
    func timeSignature(atBeat beat: Double) -> TimeSignatureChange? {
        var current: TimeSignatureChange? = timeSignatures.first
        for ts in timeSignatures where ts.beat <= beat + 1e-9 {
            current = ts
        }
        return current
    }

    /// Index of the measure containing `beat` (clamped to the last measure).
    func measureIndex(forBeat beat: Double) -> Int {
        guard !measures.isEmpty else { return 0 }
        var index = 0
        for (i, measure) in measures.enumerated() where measure.startBeat <= beat + 1e-9 {
            index = i
        }
        return index
    }
}

enum PitchMath {
    /// Semitone offset of a step letter within the octave (C = 0).
    static func semitone(forStep step: String) -> Int? {
        switch step.uppercased() {
        case "C": return 0
        case "D": return 2
        case "E": return 4
        case "F": return 5
        case "G": return 7
        case "A": return 9
        case "B": return 11
        default: return nil
        }
    }

    /// MIDI note number for a written pitch: (octave + 1) * 12 + step + alter.
    static func midi(step: String, alter: Int, octave: Int) -> Int? {
        guard let s = semitone(forStep: step) else { return nil }
        return (octave + 1) * 12 + s + alter
    }

    /// Quarter-note length of a MusicXML `<type>` (or `<beat-unit>`), ignoring dots.
    static func quarters(forNoteType type: String) -> Double? {
        switch type.lowercased() {
        case "maxima": return 32
        case "long": return 16
        case "breve": return 8
        case "whole": return 4
        case "half": return 2
        case "quarter": return 1
        case "eighth": return 0.5
        case "16th": return 0.25
        case "32nd": return 0.125
        case "64th": return 0.0625
        case "128th": return 0.03125
        case "256th": return 0.015625
        case "512th": return 0.0078125
        case "1024th": return 0.00390625
        default: return nil
        }
    }

    /// Multiplier for `dots` augmentation dots (1 dot = 1.5, 2 dots = 1.75 ...).
    static func dotFactor(dots: Int) -> Double {
        var factor = 1.0
        var add = 0.5
        var remaining = dots
        while remaining > 0 {
            factor += add
            add /= 2
            remaining -= 1
        }
        return factor
    }
}
