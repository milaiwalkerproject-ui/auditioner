import Foundation
import Combine

// "What orchestras ask" for the player's chair (PLAN D5): from the reviewed orchestra lists on
// our server when the app can reach it, otherwise from the lists cited in the app's catalogue.
// The UI always says which. "On N open auditions now" comes only from the server and is kept
// apart from the frequency (D5).

// MARK: - Items

/// Where the counts came from.
enum RecommendationSource: Hashable {
    case server
    case catalogue

    var label: String {
        switch self {
        case .server: return String(localized: "From orchestra lists on our server")
        case .catalogue: return String(localized: "From the lists in the app's catalogue")
        }
    }
}

/// One excerpt's count, whichever source it came from.
struct RecommendationItem: Hashable, Identifiable {
    let excerptId: String
    /// Recency-weighted share of lists, 0…1 (the server's is blended with other regions as a prior).
    let share: Double
    let listCount: Int
    let totalLists: Int
    /// Named only when there were at least `LocalRecommendationEngine.minimumLists` lists.
    let tier: FrequencyTier?
    let evidence: String
    /// Open auditions listing the excerpt right now; `nil` when the server hasn't said.
    let openNow: Int?
    let source: RecommendationSource

    var id: String { excerptId }

    func withOpenNow(_ count: Int?) -> RecommendationItem {
        RecommendationItem(excerptId: excerptId, share: share, listCount: listCount, totalLists: totalLists,
                           tier: tier, evidence: evidence, openNow: count, source: source)
    }
}

// MARK: - Pure helpers (tested)

enum RecommendationMerge {
    /// The server's tier, shown only under the same 5-list rule as the app's own counts.
    static func serverTier(_ raw: String, totalLists: Int) -> FrequencyTier? {
        guard totalLists >= LocalRecommendationEngine.minimumLists else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "core": return .core
        case "common": return .common
        case "occasional": return .occasional
        default: return nil
        }
    }

    static func item(fromServer recommendation: Recommendation) -> RecommendationItem? {
        let excerptId: String = recommendation.excerptId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerptId.isEmpty else { return nil }
        let share: Double = recommendation.share.isFinite ? min(1, max(0, recommendation.share)) : 0
        return RecommendationItem(excerptId: excerptId,
                                  share: share,
                                  listCount: max(0, recommendation.listCount),
                                  totalLists: max(0, recommendation.totalLists),
                                  tier: serverTier(recommendation.tier, totalLists: recommendation.totalLists),
                                  evidence: recommendation.evidence,
                                  openNow: max(0, recommendation.openNow),
                                  source: .server)
    }

    /// Server answer → items, most asked first. Duplicate ids keep the first.
    static func items(fromServer recommendations: [Recommendation]) -> [RecommendationItem] {
        var seen: Set<String> = []
        var result: [RecommendationItem] = []
        for recommendation in recommendations {
            guard let mapped = RecommendationMerge.item(fromServer: recommendation), !seen.contains(mapped.excerptId) else { continue }
            seen.insert(mapped.excerptId)
            result.append(mapped)
        }
        result.sort(by: order)
        return result
    }

    static func items(fromLocal result: LocalRecommendationResult) -> [RecommendationItem] {
        result.items.map { ask in
            RecommendationItem(excerptId: ask.excerptId, share: ask.share, listCount: ask.listCount,
                               totalLists: ask.totalLists, tier: ask.tier, evidence: ask.evidence,
                               openNow: nil, source: .catalogue)
        }
    }

    /// "On N open auditions now", by excerpt id.
    static func openNow(from recommendations: [Recommendation]) -> [String: Int] {
        var result: [String: Int] = [:]
        for recommendation in recommendations where recommendation.openNow > 0 {
            let excerptId: String = recommendation.excerptId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerptId.isEmpty else { continue }
            result[excerptId] = max(result[excerptId] ?? 0, recommendation.openNow)
        }
        return result
    }

    /// Items with the server's open-now counts attached (0 when the server knows none).
    static func applyingOpenNow(_ items: [RecommendationItem], openNow: [String: Int]?) -> [RecommendationItem] {
        guard let openNow = openNow else { return items }
        return items.map { $0.withOpenNow(openNow[$0.excerptId] ?? 0) }
    }

    /// The top `limit` excerpts that were asked at all, most asked first.
    static func top(_ items: [RecommendationItem], limit: Int) -> [RecommendationItem] {
        let asked: [RecommendationItem] = items.filter { $0.share > 0 }.sorted(by: order)
        return Array(asked.prefix(max(0, limit)))
    }

    static func order(_ a: RecommendationItem, _ b: RecommendationItem) -> Bool {
        if a.share != b.share { return a.share > b.share }
        if a.listCount != b.listCount { return a.listCount > b.listCount }
        return a.excerptId < b.excerptId
    }

    /// What to say when the server couldn't be used. `nil` when there is nothing to say
    /// (no server address set: Settings explains that).
    static func fallbackNote(for error: Error) -> String? {
        if let apiError = error as? APIError, case .notConfigured = apiError {
            return nil
        }
        return String(localized: "Couldn't reach our server, so this uses the lists in the app's catalogue.")
    }

    /// What to say when the server answered but had no lists for this chair yet.
    static var emptyServerNote: String {
        String(localized: "Our server has no reviewed lists for this chair yet, so this uses the lists in the app's catalogue.")
    }

    /// "On 1 open audition now" / "On 3 open auditions now".
    static func openNowText(_ count: Int) -> String {
        if count == 1 { return String(localized: "On 1 open audition now") }
        return String(localized: "On \(count) open auditions now")
    }
}

// MARK: - Service

/// Shared by the Excerpts browser and every excerpt page. Server answers are kept for ten
/// minutes per (instrument, position, region); the catalogue count is recomputed on every refresh.
@MainActor
final class RecommendationService: ObservableObject {
    static let shared = RecommendationService()

    static let serverCacheSeconds: TimeInterval = 600

    /// Most asked first, from `source`.
    @Published private(set) var items: [RecommendationItem] = []
    @Published private(set) var source: RecommendationSource = .catalogue
    /// The catalogue count for the last query (also when the server is used, for its notes).
    @Published private(set) var local: LocalRecommendationResult?
    @Published private(set) var isLoading: Bool = false
    /// Why the catalogue is used although a server is set, or `nil`.
    @Published private(set) var serverNote: String?
    /// Open auditions by excerpt id from the server; `nil` until it answered.
    @Published private(set) var openNow: [String: Int]?

    private struct ServerKey: Hashable {
        let instrument: Instrument
        let position: Position
        let region: String?
    }

    private var cachedServerItems: [RecommendationItem]?
    private var cachedServerKey: ServerKey?
    private var cachedAt: Date?
    private var generation: Int = 0

    init() {}

    /// The instrument the current items are for.
    var instrument: Instrument? { local?.query.instrument }

    func item(for excerptId: String) -> RecommendationItem? {
        items.first { $0.excerptId == excerptId }
    }

    /// Open auditions now for an excerpt of `instrument`: `nil` until the server has answered
    /// for that instrument, else the count (0 when none).
    func openNowCount(for excerptId: String, instrument: Instrument) -> Int? {
        guard let openNow = openNow, cachedServerKey?.instrument == instrument else { return nil }
        return openNow[excerptId] ?? 0
    }

    /// Recomputes the catalogue count at once, then asks the server (when one is set) and swaps
    /// to its answer. Safe to call again while a request is running: the older answer is dropped.
    func refresh(excerpts: [Excerpt], query: RecommendationQuery, client: APIClient) async {
        let result: LocalRecommendationResult = LocalRecommendationEngine.compute(excerpts: excerpts, query: query)
        local = result
        let key = ServerKey(instrument: query.instrument, position: query.position, region: query.region)
        generation += 1
        let myGeneration: Int = generation
        // A request started by an earlier refresh is dropped when it answers (generation check).
        isLoading = false

        if let cached = cachedServerItems, cachedServerKey == key, let at = cachedAt,
           Date().timeIntervalSince(at) < RecommendationService.serverCacheSeconds {
            publish(server: cached, local: result, note: nil)
            return
        }

        guard client.baseURL != nil else {
            publish(server: nil, local: result, note: nil)
            return
        }

        publish(server: nil, local: result, note: nil)
        isLoading = true
        do {
            let answer: [Recommendation] = try await client.recommendations(instrument: query.instrument,
                                                                            position: query.position,
                                                                            region: query.region)
            guard myGeneration == generation else { return }
            let mapped: [RecommendationItem] = RecommendationMerge.items(fromServer: answer)
            cachedServerItems = mapped
            cachedServerKey = key
            cachedAt = Date()
            publish(server: mapped, local: result, note: nil)
        } catch {
            guard myGeneration == generation else { return }
            publish(server: nil, local: result, note: RecommendationMerge.fallbackNote(for: error))
        }
        isLoading = false
    }

    /// Drops the cached server answer (e.g. after the server address changed).
    func forgetServerAnswer() {
        cachedServerItems = nil
        cachedServerKey = nil
        cachedAt = nil
    }

    private func publish(server: [RecommendationItem]?, local result: LocalRecommendationResult, note: String?) {
        if let server = server, !server.isEmpty {
            let counts: [String: Int] = Dictionary(server.map { ($0.excerptId, $0.openNow ?? 0) },
                                                   uniquingKeysWith: { max($0, $1) })
            openNow = counts
            items = server
            source = .server
            serverNote = nil
            return
        }
        if let server = server, server.isEmpty {
            // The server answered: nothing open, nothing counted for this chair yet.
            openNow = [:]
            items = RecommendationMerge.applyingOpenNow(RecommendationMerge.items(fromLocal: result), openNow: [:])
            source = .catalogue
            serverNote = RecommendationMerge.emptyServerNote
            return
        }
        openNow = nil
        items = RecommendationMerge.items(fromLocal: result)
        source = .catalogue
        serverNote = note
    }
}

// MARK: - One excerpt's summary (for its page)

/// What the "How often it's asked" section shows: the catalogue count for this excerpt (checkable
/// against the sources listed under it) plus the server's open-now count when it has one.
struct ExcerptAskSummary: Hashable {
    let ask: ExcerptAsk
    let notes: [String]
    let notEnoughListsNote: String?
    let openNow: Int?

    var tier: FrequencyTier? { ask.tier }
    var sourceLabel: String { RecommendationSource.catalogue.label }

    static func make(excerptId: String, catalogExcerpts: [Excerpt], query: RecommendationQuery, openNow: Int?) -> ExcerptAskSummary {
        let result: LocalRecommendationResult = LocalRecommendationEngine.compute(excerpts: catalogExcerpts, query: query)
        return ExcerptAskSummary(ask: result.ask(for: excerptId),
                                 notes: result.notes,
                                 notEnoughListsNote: LocalRecommendationEngine.notEnoughListsNote(totalLists: result.totalLists),
                                 openNow: openNow)
    }
}
