import Foundation

/// The note value that gets the BPM number (a label; the click interval is always 60 / BPM).
enum BeatUnit: String, Codable, CaseIterable, Identifiable {
    case half
    case quarter
    case dottedQuarter
    case eighth

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .half: return "𝅗𝅥"
        case .quarter: return "♩"
        case .dottedQuarter: return "♩."
        case .eighth: return "♪"
        }
    }

    var displayName: String {
        switch self {
        case .half: return String(localized: "Half note")
        case .quarter: return String(localized: "Quarter note")
        case .dottedQuarter: return String(localized: "Dotted quarter")
        case .eighth: return String(localized: "Eighth note")
        }
    }
}

/// Ticks per beat.
enum Subdivision: Int, Codable, CaseIterable, Identifiable {
    case none = 1
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        }
    }
}

/// Everything the metronome needs to run. Saved per excerpt as JSON.
struct MetronomeSettings: Codable, Equatable {
    var bpm: Double = 80
    var beatsPerBar: Int = 4
    var beatUnit: BeatUnit = .quarter
    var subdivision: Subdivision = .none
    var accentFirstBeat: Bool = true
    var sound: ClickSound = .woodblock

    init(bpm: Double = 80, beatsPerBar: Int = 4, beatUnit: BeatUnit = .quarter, subdivision: Subdivision = .none,
         accentFirstBeat: Bool = true, sound: ClickSound = .woodblock) {
        self.bpm = MetronomeMath.clampBPM(bpm)
        self.beatsPerBar = MetronomeMath.clampBeatsPerBar(beatsPerBar)
        self.beatUnit = beatUnit
        self.subdivision = subdivision
        self.accentFirstBeat = accentFirstBeat
        self.sound = sound
    }

    private enum CodingKeys: String, CodingKey {
        case bpm, beatsPerBar, beatUnit, subdivision, accentFirstBeat, sound
    }

    /// Tolerant decoding so presets saved by an older version still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try container.decodeIfPresent(Double.self, forKey: .bpm) ?? 80
        let beats = try container.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4
        let unit = try container.decodeIfPresent(BeatUnit.self, forKey: .beatUnit) ?? .quarter
        let sub = try container.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .none
        let accent = try container.decodeIfPresent(Bool.self, forKey: .accentFirstBeat) ?? true
        let sound = try container.decodeIfPresent(ClickSound.self, forKey: .sound) ?? .woodblock
        self.init(bpm: bpm, beatsPerBar: beats, beatUnit: unit, subdivision: sub, accentFirstBeat: accent, sound: sound)
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decoded(from data: Data) -> MetronomeSettings? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(MetronomeSettings.self, from: data)
    }
}

/// Pure timing math for the metronome (unit-tested). "Tick" counts subdivisions; "beat" counts clicks of the bar.
enum MetronomeMath {
    static let bpmRange: ClosedRange<Double> = 30...300
    static let beatsPerBarRange: ClosedRange<Int> = 1...12

    static func clampBPM(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return bpmRange.lowerBound }
        return min(bpmRange.upperBound, max(bpmRange.lowerBound, bpm))
    }

    static func clampBeatsPerBar(_ beats: Int) -> Int {
        min(beatsPerBarRange.upperBound, max(beatsPerBarRange.lowerBound, beats))
    }

    static func secondsPerBeat(bpm: Double) -> Double {
        60.0 / max(1, bpm)
    }

    static func secondsPerTick(bpm: Double, subdivision: Subdivision) -> Double {
        secondsPerBeat(bpm: bpm) / Double(subdivision.rawValue)
    }

    /// Sample frame of tick `n` (0-based) counted from the first tick, computed from `n` directly so there is no drift.
    static func frame(ofTick n: Int, bpm: Double, sampleRate: Double, subdivision: Subdivision) -> Int64 {
        let seconds = Double(n) * secondsPerTick(bpm: bpm, subdivision: subdivision)
        return Int64((seconds * sampleRate).rounded())
    }

    /// 0-based beat within the bar for tick `n`, when tick 0 falls on beat `startBeat`.
    static func beatInBar(tick n: Int, beatsPerBar: Int, subdivision: Subdivision, startBeat: Int = 0) -> Int {
        let bars = max(1, beatsPerBar)
        let beat = startBeat + n / subdivision.rawValue
        return ((beat % bars) + bars) % bars
    }

    static func isSubdivisionTick(_ n: Int, subdivision: Subdivision) -> Bool {
        n % subdivision.rawValue != 0
    }

    static func tickKind(tick n: Int, beatsPerBar: Int, subdivision: Subdivision, accentFirstBeat: Bool, startBeat: Int = 0) -> TickKind {
        if isSubdivisionTick(n, subdivision: subdivision) { return .subdivision }
        let beat = beatInBar(tick: n, beatsPerBar: beatsPerBar, subdivision: subdivision, startBeat: startBeat)
        return (accentFirstBeat && beat == 0) ? .accent : .beat
    }

    /// Taps older than this start a new measurement.
    static let tapResetSeconds: Double = 2.5

    /// Tempo from tap times (seconds, ascending): the average interval of the last four taps, clamped to the BPM range.
    /// `nil` with fewer than two usable taps.
    static func tapTempo(tapTimes: [TimeInterval]) -> Double? {
        let recent = Array(tapTimes.suffix(4))
        guard recent.count >= 2 else { return nil }
        var total: Double = 0
        var intervals = 0
        for i in 1..<recent.count {
            let interval = recent[i] - recent[i - 1]
            guard interval > 0.05, interval <= tapResetSeconds else { return nil }
            total += interval
            intervals += 1
        }
        guard intervals > 0 else { return nil }
        let average = total / Double(intervals)
        return clampBPM((60.0 / average).rounded())
    }

    /// Keeps only the taps that belong to the current measurement (drops everything before a long gap).
    static func trimmedTaps(_ tapTimes: [TimeInterval], adding newTap: TimeInterval) -> [TimeInterval] {
        if let last = tapTimes.last, newTap - last > tapResetSeconds {
            return [newTap]
        }
        return Array((tapTimes + [newTap]).suffix(8))
    }

    /// Conventional tempo-marking ranges, shown as a rough guide only (not a claim about any excerpt).
    static let markingRanges: [(name: String, range: ClosedRange<Double>)] = [
        ("Grave", 30...40),
        ("Largo", 40...60),
        ("Larghetto", 60...66),
        ("Adagio", 66...76),
        ("Andante", 76...108),
        ("Moderato", 108...120),
        ("Allegro", 120...168),
        ("Presto", 168...200),
        ("Prestissimo", 200...300),
    ]

    /// Name of the conventional marking range `bpm` falls in, e.g. "Allegro".
    static func tempoMarkingName(bpm: Double) -> String {
        for item in markingRanges where item.range.contains(bpm) {
            return item.name
        }
        return markingRanges.last?.name ?? ""
    }

    /// "Allegro range (120–168)" style hint.
    static func tempoMarkingHint(bpm: Double) -> String {
        for item in markingRanges where item.range.contains(bpm) {
            let lo = Int(item.range.lowerBound)
            let hi = Int(item.range.upperBound)
            return "\(item.name) · \(lo)–\(hi)"
        }
        return ""
    }
}
