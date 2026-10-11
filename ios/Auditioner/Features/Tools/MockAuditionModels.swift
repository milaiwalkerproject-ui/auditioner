import Foundation

/// One excerpt in a mock audition run. Stored as JSON in `MockAuditionRun.itemsData`.
struct MockAuditionItem: Codable, Equatable {
    var title: String
    var excerptId: String?
    var scoreId: UUID?
    /// Seconds into the run's recording (or into the run, when nothing was recorded) where this excerpt started.
    var startOffsetSeconds: Double?
    /// Self-rating 1–5.
    var rating: Int?

    init(title: String, excerptId: String? = nil, scoreId: UUID? = nil, startOffsetSeconds: Double? = nil, rating: Int? = nil) {
        self.title = title
        self.excerptId = excerptId
        self.scoreId = scoreId
        self.startOffsetSeconds = startOffsetSeconds
        self.rating = rating
    }
}

enum MockAuditionOrder: String, CaseIterable, Identifiable {
    case asListed
    case random

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asListed: return String(localized: "As listed")
        case .random: return String(localized: "Random")
        }
    }
}

/// What the setup screen hands to the run screen.
struct MockAuditionConfig: Equatable {
    var items: [MockAuditionItem]
    var hideTitles: Bool
    var prepSeconds: Int
    var recordWholeRun: Bool
}

/// Pure helpers for mock auditions (unit-tested).
enum MockAuditionLogic {
    /// Preparation time between excerpts, in seconds.
    static let prepChoices: [Int] = [0, 15, 30, 60]

    static func encode(_ items: [MockAuditionItem]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(items)) ?? Data()
    }

    static func decode(_ data: Data) -> [MockAuditionItem] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([MockAuditionItem].self, from: data)) ?? []
    }

    /// The items in the chosen order. Random order keeps every item exactly once.
    static func ordered<G: RandomNumberGenerator>(_ items: [MockAuditionItem], order: MockAuditionOrder, using generator: inout G) -> [MockAuditionItem] {
        switch order {
        case .asListed:
            return items
        case .random:
            return items.shuffled(using: &generator)
        }
    }

    static func ordered(_ items: [MockAuditionItem], order: MockAuditionOrder) -> [MockAuditionItem] {
        var generator = SystemRandomNumberGenerator()
        return ordered(items, order: order, using: &generator)
    }

    /// "Excerpt 2 of 6" — what the player sees behind the screen (index is 0-based).
    static func hiddenTitle(index: Int, count: Int) -> String {
        String(localized: "Excerpt \(index + 1) of \(max(count, index + 1))")
    }

    /// Title shown for an item: hidden while the run is on, real afterwards.
    static func displayTitle(for item: MockAuditionItem, index: Int, count: Int, hideTitles: Bool) -> String {
        hideTitles ? hiddenTitle(index: index, count: count) : item.title
    }

    /// "Mock audition · 11 Oct 2026, 14:30" style title for a saved run.
    static func runTitle(date: Date) -> String {
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Mock audition · \(stamp)")
    }

    /// Mean of the ratings that were given, `nil` when none.
    static func averageRating(_ items: [MockAuditionItem]) -> Double? {
        let ratings = items.compactMap { $0.rating }
        guard !ratings.isEmpty else { return nil }
        return Double(ratings.reduce(0, +)) / Double(ratings.count)
    }

    static func clampRating(_ rating: Int?) -> Int? {
        guard let r = rating else { return nil }
        return min(5, max(1, r))
    }

    /// Which catalogue excerpts a finished run counts as practised (PLAN D6), under each excerpt's
    /// **own** instrument — a run can mix instruments, and the player's instrument in Settings says
    /// nothing about what was played. `instrumentOf` looks an id up in the catalogue; an id it doesn't
    /// know is skipped, as are typed items and scans without an excerpt id. Ids are sorted, no repeats.
    static func practisedExcerpts(_ items: [MockAuditionItem],
                                  instrumentOf: (String) -> Instrument?) -> [Instrument: [String]] {
        var byInstrument: [Instrument: Set<String>] = [:]
        for item in items {
            guard let excerptId: String = item.excerptId, let instrument: Instrument = instrumentOf(excerptId) else { continue }
            byInstrument[instrument, default: []].insert(excerptId)
        }
        return byInstrument.mapValues { (ids: Set<String>) -> [String] in ids.sorted() }
    }
}

/// Deterministic generator (SplitMix64) for tests and previews.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
