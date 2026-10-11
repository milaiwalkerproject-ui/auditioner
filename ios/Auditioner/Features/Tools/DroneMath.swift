import Foundation

/// A pitch class in equal temperament, C = 0.
enum PitchClass: Int, Codable, CaseIterable, Identifiable {
    case c = 0, cSharp, d, eFlat, e, f, fSharp, g, aFlat, a, bFlat, b

    var id: Int { rawValue }

    /// Common orchestral spelling.
    var displayName: String {
        switch self {
        case .c: return "C"
        case .cSharp: return "C♯"
        case .d: return "D"
        case .eFlat: return "E♭"
        case .e: return "E"
        case .f: return "F"
        case .fSharp: return "F♯"
        case .g: return "G"
        case .aFlat: return "A♭"
        case .a: return "A"
        case .bFlat: return "B♭"
        case .b: return "B"
        }
    }
}

/// What the drone sounds like.
enum DroneSound: String, Codable, CaseIterable, Identifiable {
    case instrument
    case pureTone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instrument: return String(localized: "Instrument sound")
        case .pureTone: return String(localized: "Pure tone")
        }
    }
}

/// The note a drone plays: pitch class + octave in scientific pitch notation (A4 = 440 Hz region).
struct DroneNote: Codable, Equatable {
    var pitchClass: PitchClass
    var octave: Int

    static let octaveRange: ClosedRange<Int> = 1...6

    init(pitchClass: PitchClass, octave: Int) {
        self.pitchClass = pitchClass
        self.octave = min(DroneNote.octaveRange.upperBound, max(DroneNote.octaveRange.lowerBound, octave))
    }

    /// MIDI note number ((octave + 1) * 12 + pitch class).
    var midi: Int { DroneMath.midi(pitchClass: pitchClass, octave: octave) }

    /// "A3" style name.
    var displayName: String { "\(pitchClass.displayName)\(octave)" }

    /// The same note a fifth higher.
    var fifthAbove: DroneNote {
        let m = midi + 7
        return DroneMath.note(midi: m)
    }
}

/// Equal-temperament maths (unit-tested).
enum DroneMath {
    static func midi(pitchClass: PitchClass, octave: Int) -> Int {
        (octave + 1) * 12 + pitchClass.rawValue
    }

    static func note(midi: Int) -> DroneNote {
        let clamped = max(0, min(127, midi))
        let octave = clamped / 12 - 1
        let pitchClass = PitchClass(rawValue: clamped % 12) ?? .c
        return DroneNote(pitchClass: pitchClass, octave: octave)
    }

    /// Frequency in Hz of a MIDI note when A4 (MIDI 69) is tuned to `a4` Hz.
    static func frequency(midi: Int, a4: Double) -> Double {
        let tuning = (a4.isFinite && a4 > 0) ? a4 : 440
        return tuning * pow(2.0, Double(midi - 69) / 12.0)
    }

    /// Cents to retune a sampler tuned to A = 440 so that A sounds at `a4`.
    static func cents(forA4 a4: Double) -> Double {
        let tuning = (a4.isFinite && a4 > 0) ? a4 : 440
        return 1200.0 * log2(tuning / 440.0)
    }

    /// "220.0 Hz" style text.
    static func frequencyText(_ hz: Double) -> String {
        String(format: "%.1f Hz", hz)
    }
}
