import Foundation
import Combine

// "Popular with cello players" (PLAN D6): what players who share practised in the last eight ISO
// weeks, as tiers only. Never mixed into "what orchestras ask" — nothing here touches
// `RecommendationService` or `FrequencyTier`.

// MARK: - Tiers

/// A popularity tier from the server. Tiers only, never counts or shares (D6).
enum TrendTier: String, Hashable, CaseIterable {
    case veryPopular = "very-popular"
    case popular

    init?(serverValue: String) {
        switch serverValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "very-popular", "very_popular": self = .veryPopular
        case "popular": self = .popular
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .veryPopular: return String(localized: "Very popular")
        case .popular: return String(localized: "Popular")
        }
    }

    /// Very popular first.
    var order: Int {
        switch self {
        case .veryPopular: return 0
        case .popular: return 1
        }
    }
}

/// One instrument's answer, cleaned.
struct TrendsAnswer: Hashable {
    let enough: Bool
    let fromWeek: String
    let toWeek: String
    /// Excerpt id → tier; only ids the server named with a tier the app knows.
    let tiers: [String: TrendTier]
    /// Very popular first, then popular; within a tier in the server's order (which is by id, so
    /// nothing finer than the tier shows).
    let ordered: [String]

    func tier(for excerptId: String) -> TrendTier? {
        tiers[excerptId]
    }
}

/// One row of the browser section.
struct PopularEntry: Identifiable, Hashable {
    let excerpt: Excerpt
    let tier: TrendTier

    var id: String { excerpt.id }
}

// MARK: - Pure helpers (tested)

enum TrendsLogic {
    static let maxExcerptIdLength: Int = 128

    /// A catalogue-shaped excerpt id: trimmed, not empty, no spaces inside, at most 128 characters.
    /// Anything else is dropped (the server also drops ids its catalogue doesn't know).
    static func cleanExcerptId(_ raw: String) -> String? {
        let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxExcerptIdLength else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return trimmed
    }

    /// The server's answer → a cleaned one. Unknown tiers and repeated ids are dropped; below
    /// 20 contributors (`enough == false`) nothing is kept.
    static func answer(from response: TrendsResponse) -> TrendsAnswer {
        guard response.enough else {
            return TrendsAnswer(enough: false, fromWeek: response.fromWeek, toWeek: response.toWeek, tiers: [:], ordered: [])
        }
        var tiers: [String: TrendTier] = [:]
        var ordered: [String] = []
        for entry in response.trends {
            guard let id = cleanExcerptId(entry.excerptId),
                  let tier = TrendTier(serverValue: entry.tier),
                  tiers[id] == nil else { continue }
            tiers[id] = tier
            ordered.append(id)
        }
        // Stable: tier first, then the server's order.
        let indexed: [(offset: Int, element: String)] = Array(ordered.enumerated())
        let sorted: [String] = indexed.sorted { a, b in
            let tierA: Int = tiers[a.element]?.order ?? Int.max
            let tierB: Int = tiers[b.element]?.order ?? Int.max
            if tierA != tierB { return tierA < tierB }
            return a.offset < b.offset
        }.map { $0.element }
        return TrendsAnswer(enough: true, fromWeek: response.fromWeek, toWeek: response.toWeek, tiers: tiers, ordered: sorted)
    }

    /// The popular excerpts that are in `pool` (the catalogue on this device), very popular first.
    static func entries(_ answer: TrendsAnswer?, in pool: [Excerpt]) -> [PopularEntry] {
        guard let answer = answer, answer.enough else { return [] }
        var byId: [String: Excerpt] = [:]
        for excerpt in pool where byId[excerpt.id] == nil {
            byId[excerpt.id] = excerpt
        }
        return answer.ordered.compactMap { (id: String) -> PopularEntry? in
            guard let excerpt = byId[id], let tier = answer.tiers[id] else { return nil }
            return PopularEntry(excerpt: excerpt, tier: tier)
        }
    }

    /// Why nothing could be shown, in plain words. A 503 carries the server's own sentence
    /// ("Sharing what you practise isn't set up on the server yet.").
    static func note(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .notConfigured:
                return String(localized: "Needs the Auditioner server. Add its address in Settings → Server.")
            case .server(let status, let message):
                if status == 503, !message.isEmpty { return message }
                return String(localized: "Couldn't check what other players practise. Try again later.")
            case .invalidResponse:
                return String(localized: "Couldn't check what other players practise. Try again later.")
            }
        }
        return String(localized: "Couldn't reach our server to check what other players practise.")
    }
}

// MARK: - Service

/// Shared by the Excerpts browser and the excerpt pages. One answer per instrument, kept an hour
/// (the server caches for an hour too). Only ever asked when the player shares — nothing is shown
/// otherwise — but the service itself doesn't check that.
@MainActor
final class TrendsService: ObservableObject {
    static let shared = TrendsService()

    static let cacheSeconds: TimeInterval = 3600

    @Published private(set) var answers: [Instrument: TrendsAnswer] = [:]
    /// Why an instrument has no fresh answer (server message or plain words), by instrument.
    @Published private(set) var notes: [Instrument: String] = [:]
    @Published private(set) var loading: Set<Instrument> = []

    private var fetchedAt: [Instrument: Date] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func answer(for instrument: Instrument) -> TrendsAnswer? {
        answers[instrument]
    }

    func note(for instrument: Instrument) -> String? {
        notes[instrument]
    }

    func isLoading(_ instrument: Instrument) -> Bool {
        loading.contains(instrument)
    }

    /// The tier for one excerpt, or `nil` (no answer yet, not enough players, or not popular).
    func tier(for excerptId: String, instrument: Instrument) -> TrendTier? {
        answers[instrument]?.tier(for: excerptId)
    }

    func isFresh(_ instrument: Instrument) -> Bool {
        guard answers[instrument] != nil, let at = fetchedAt[instrument] else { return false }
        let age: TimeInterval = now().timeIntervalSince(at)
        return age >= 0 && age < TrendsService.cacheSeconds
    }

    /// Asks the server unless the answer is less than an hour old. One request per instrument at a
    /// time; on failure the old answer (if any) stays and `notes` says why.
    func refresh(instrument: Instrument, client: TrendsAPI, force: Bool = false) async {
        if !force, isFresh(instrument) { return }
        if loading.contains(instrument) { return }
        loading.insert(instrument)
        defer { loading.remove(instrument) }
        do {
            let response: TrendsResponse = try await client.trends(instrument: instrument)
            answers[instrument] = TrendsLogic.answer(from: response)
            notes[instrument] = nil
            fetchedAt[instrument] = now()
        } catch {
            notes[instrument] = TrendsLogic.note(for: error)
        }
    }

    /// Drops every answer (e.g. after the server address changed).
    func forget() {
        answers = [:]
        notes = [:]
        fetchedAt = [:]
    }
}
