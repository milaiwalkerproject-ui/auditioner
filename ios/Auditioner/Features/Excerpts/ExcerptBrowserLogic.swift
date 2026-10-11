import Foundation

/// Position filter in the browser: everything, or one position (an excerpt tagged `any` matches every position).
enum ExcerptPositionFilter: Hashable {
    case all
    case position(Position)
}

/// Frequency filter in the browser. Only verified tiers count: an excerpt whose tier is
/// not verified is hidden by every choice except `.all`.
enum ExcerptTierFilter: Hashable {
    case all
    case tier(FrequencyTier)
}

/// One group of rows in the browser, by composer surname.
struct ExcerptSection: Identifiable {
    let id: String
    let title: String
    let excerpts: [Excerpt]
}

/// Pure filtering and grouping for `ExcerptBrowserView` (unit-tested).
enum ExcerptBrowserLogic {
    static func matches(_ excerpt: Excerpt, position: ExcerptPositionFilter) -> Bool {
        switch position {
        case .all:
            return true
        case .position(let wanted):
            if wanted == .any { return true }
            return excerpt.positions.contains(wanted) || excerpt.positions.contains(.any)
        }
    }

    static func matches(_ excerpt: Excerpt, tier: ExcerptTierFilter) -> Bool {
        switch tier {
        case .all:
            return true
        case .tier(let wanted):
            return excerpt.frequency?.verifiedTier == wanted
        }
    }

    static func filter(_ excerpts: [Excerpt], position: ExcerptPositionFilter, tier: ExcerptTierFilter) -> [Excerpt] {
        excerpts.filter { matches($0, position: position) && matches($0, tier: tier) }
    }

    /// Groups by composer surname, sections A→Z, rows by work then movement then title.
    static func group(_ excerpts: [Excerpt]) -> [ExcerptSection] {
        var buckets: [String: [Excerpt]] = [:]
        for excerpt in excerpts {
            let surname = ExcerptFormat.surname(excerpt.composer)
            buckets[surname, default: []].append(excerpt)
        }
        let surnames: [String] = buckets.keys.sorted { ExcerptFormat.sortKey($0) < ExcerptFormat.sortKey($1) }
        return surnames.map { surname in
            let rows: [Excerpt] = (buckets[surname] ?? []).sorted(by: rowOrder)
            return ExcerptSection(id: surname, title: surname, excerpts: rows)
        }
    }

    private static func rowOrder(_ a: Excerpt, _ b: Excerpt) -> Bool {
        let workA = ExcerptFormat.sortKey(a.work)
        let workB = ExcerptFormat.sortKey(b.work)
        if workA != workB { return workA < workB }
        let movementA = a.movement?.number ?? 0
        let movementB = b.movement?.number ?? 0
        if movementA != movementB { return movementA < movementB }
        return ExcerptFormat.sortKey(a.title) < ExcerptFormat.sortKey(b.title)
    }

    /// Instruments that have catalogue content, in `Instrument.allCases` order, and the rest.
    static func orderedInstruments(withContent: [Instrument]) -> (first: [Instrument], more: [Instrument]) {
        let contentSet = Set(withContent)
        let first = Instrument.allCases.filter { contentSet.contains($0) }
        let more = Instrument.allCases.filter { !contentSet.contains($0) }
        return (first, more)
    }

    /// Position choices offered in the filter menu (`any` is covered by "All positions").
    static var filterablePositions: [Position] {
        Position.allCases.filter { $0 != .any }
    }

    // MARK: Most asked for your chair

    /// How many excerpts the "Most asked for your chair" section shows.
    static let mostAskedLimit: Int = 5

    /// The section sits on the plain list only: a search or a filter means the player is looking
    /// for something specific.
    static func showsMostAsked(query: String, isFiltering: Bool) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isFiltering
    }

    /// The top excerpts that are in `pool` (the catalogue on this device), most asked first.
    static func mostAsked(_ items: [RecommendationItem], in pool: [Excerpt], limit: Int = mostAskedLimit) -> [MostAskedEntry] {
        var byId: [String: Excerpt] = [:]
        for excerpt in pool where byId[excerpt.id] == nil {
            byId[excerpt.id] = excerpt
        }
        let known: [RecommendationItem] = items.filter { byId[$0.excerptId] != nil }
        return RecommendationMerge.top(known, limit: limit).compactMap { (item: RecommendationItem) -> MostAskedEntry? in
            guard let excerpt = byId[item.excerptId] else { return nil }
            return MostAskedEntry(excerpt: excerpt, item: item)
        }
    }
}

/// One row of "Most asked for your chair".
struct MostAskedEntry: Identifiable {
    let excerpt: Excerpt
    let item: RecommendationItem

    var id: String { excerpt.id }
}
