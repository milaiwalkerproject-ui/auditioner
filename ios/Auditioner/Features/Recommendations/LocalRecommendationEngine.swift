import Foundation

// PLAN D5 "What orchestras ask", worked out on the device from the catalogue's own evidence
// rows (`frequency.evidence`: one row per audition list an excerpt was seen on, each with the
// list's source). Pure functions, no UI, no network, so every rule is unit-tested.
//
// Honesty contract: nothing here knows a musical fact. It only counts the lists the catalogue
// cites, says how many it counted, and names a tier only once there are enough of them.

// MARK: - Query

/// What the player wants counted.
struct RecommendationQuery: Hashable {
    var instrument: Instrument
    var position: Position
    /// Region id from `ProfileOptions.regions`; `nil` counts lists from every region.
    var region: String?
    /// Count lists for every chair (and lists that don't name one), not only the player's.
    var includeAllChairs: Bool = false
    /// Draft excerpts count only in reviewer mode.
    var includeDrafts: Bool = false
    /// The year the recency weight is measured from (normally this year).
    var currentYear: Int
}

// MARK: - Results

/// One audition list we've collected, as cited in the catalogue. The same list cited by several
/// excerpts is one list.
struct CollectedList: Hashable, Identifiable {
    /// `source|year|position`: a page that hosts a new list every year is a new list each year.
    let id: String
    let source: String
    let orchestra: String?
    let year: Int?
    let region: String?
    let position: Position?
    /// Recency weight: 1 for this year, 0.5 three years ago, 0.25 six years ago.
    let weight: Double
}

/// How often one excerpt was asked, in the lists considered.
struct ExcerptAsk: Hashable, Identifiable {
    let excerptId: String
    /// Lists (in scope) that include the excerpt.
    let listCount: Int
    /// Lists considered.
    let totalLists: Int
    /// Recency-weighted share of lists, 0…1.
    let share: Double
    /// Named only when `totalLists >= LocalRecommendationEngine.minimumLists`.
    let tier: FrequencyTier?
    /// Plain words: "On 7 of the 9 section cello lists we've collected (2022–2026)".
    let evidence: String

    var id: String { excerptId }
}

struct LocalRecommendationResult: Hashable {
    let query: RecommendationQuery
    /// Lists considered, newest first.
    let lists: [CollectedList]
    /// The player's region had fewer than `minimumLists` lists, so every region was counted.
    let fellBackToAllRegions: Bool
    /// Lists without a year (they count as the oldest year present).
    let undatedLists: Int
    let oldestYear: Int?
    /// Lists left out because they don't say which chair they were for (exact-chair mode only).
    let listsWithoutChair: Int
    /// Excerpts seen on at least one list in scope, most asked first.
    let items: [ExcerptAsk]

    var totalLists: Int { lists.count }

    var hasEnoughLists: Bool { totalLists >= LocalRecommendationEngine.minimumLists }

    /// Earliest…latest year among the lists considered.
    var yearSpan: ClosedRange<Int>? {
        let years: [Int] = lists.compactMap { $0.year }
        guard let low = years.min(), let high = years.max() else { return nil }
        return low...high
    }

    func item(for excerptId: String) -> ExcerptAsk? {
        items.first { $0.excerptId == excerptId }
    }

    /// The count for any excerpt of the instrument, also one seen on no list in scope.
    func ask(for excerptId: String) -> ExcerptAsk {
        if let found = item(for: excerptId) { return found }
        return ExcerptAsk(excerptId: excerptId, listCount: 0, totalLists: totalLists, share: 0, tier: nil,
                          evidence: LocalRecommendationEngine.evidenceText(listCount: 0, totalLists: totalLists,
                                                                           instrument: query.instrument,
                                                                           position: query.position,
                                                                           includeAllChairs: query.includeAllChairs,
                                                                           years: yearSpan))
    }

    /// Plain-words caveats to show once under the list: region scope, undated lists, lists without a chair.
    var notes: [String] {
        LocalRecommendationEngine.notes(for: self)
    }
}

// MARK: - Engine

enum LocalRecommendationEngine {
    /// A tier is named only from this many lists (PLAN D5; fewer is "not enough lists yet").
    static let minimumLists: Int = 5
    /// Recency half-life in years (PLAN D5).
    static let halfLifeYears: Double = 3
    static let coreThreshold: Double = 0.5
    static let commonThreshold: Double = 0.2

    // MARK: Rules

    /// 2^(-(yearsAgo)/3): this year 1, three years ago 0.5, six years ago 0.25. A list without a
    /// year counts as the oldest year present; when no list has a year every list counts 1.
    static func weight(year: Int?, currentYear: Int, oldestYear: Int?) -> Double {
        guard let effectiveYear = year ?? oldestYear else { return 1 }
        let yearsAgo: Int = max(0, currentYear - effectiveYear)
        return pow(2.0, -Double(yearsAgo) / halfLifeYears)
    }

    /// Identity of a list: its source, the year and the chair it was for.
    static func listKey(_ evidence: FrequencyEvidence) -> String {
        let source: String = evidence.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let year: String = evidence.year.map { String($0) } ?? ""
        let position: String = evidence.position?.rawValue ?? ""
        return source + "|" + year + "|" + position
    }

    /// Exact chair: the list was for the player's chair, or for any chair. A list that doesn't say
    /// which chair counts only with "Include all chairs".
    static func matchesChair(_ listPosition: Position?, wanted: Position, includeAllChairs: Bool) -> Bool {
        if includeAllChairs || wanted == .any { return true }
        guard let listPosition = listPosition else { return false }
        return listPosition == wanted || listPosition == .any
    }

    static func tier(share: Double, totalLists: Int) -> FrequencyTier? {
        guard totalLists >= minimumLists else { return nil }
        if share >= coreThreshold { return .core }
        if share >= commonThreshold { return .common }
        return .occasional
    }

    // MARK: Compute

    private struct Row {
        let excerptId: String
        let evidence: FrequencyEvidence
        let key: String
    }

    static func compute(excerpts: [Excerpt], query: RecommendationQuery) -> LocalRecommendationResult {
        // 1. Every evidence row of the instrument (published excerpts, drafts in reviewer mode).
        var rows: [Row] = []
        for excerpt in excerpts {
            guard excerpt.instrument == query.instrument else { continue }
            guard query.includeDrafts || excerpt.listingStatus == .published else { continue }
            for evidence in excerpt.frequency?.evidence ?? [] {
                let source: String = evidence.source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { continue }
                rows.append(Row(excerptId: excerpt.id, evidence: evidence, key: listKey(evidence)))
            }
        }

        // 2. Chair.
        var chairRows: [Row] = []
        var skippedChairKeys: Set<String> = []
        for row in rows {
            if matchesChair(row.evidence.position, wanted: query.position, includeAllChairs: query.includeAllChairs) {
                chairRows.append(row)
            } else if row.evidence.position == nil {
                skippedChairKeys.insert(row.key)
            }
        }

        // 3. Region, falling back to every region when the player's has too few lists.
        var scoped: [Row] = chairRows
        var fellBack: Bool = false
        if let region = query.region {
            let inRegion: [Row] = chairRows.filter { $0.evidence.region == region }
            let regionKeys: Set<String> = Set(inRegion.map { $0.key })
            let allKeys: Set<String> = Set(chairRows.map { $0.key })
            if regionKeys.count < minimumLists && allKeys.count > regionKeys.count {
                fellBack = true
            } else {
                scoped = inRegion
            }
        }

        // 4. Distinct lists, with recency weights.
        var firstRowByKey: [String: FrequencyEvidence] = [:]
        var keyOrder: [String] = []
        for row in scoped where firstRowByKey[row.key] == nil {
            firstRowByKey[row.key] = row.evidence
            keyOrder.append(row.key)
        }
        let oldestYear: Int? = firstRowByKey.values.compactMap { $0.year }.min()
        var lists: [CollectedList] = keyOrder.map { key in
            let evidence: FrequencyEvidence = firstRowByKey[key] ?? FrequencyEvidence(description: "", source: "", asOf: "")
            let orchestra: String? = evidence.orchestra.flatMap { $0.isEmpty ? nil : $0 }
            return CollectedList(id: key,
                                 source: evidence.source.trimmingCharacters(in: .whitespacesAndNewlines),
                                 orchestra: orchestra,
                                 year: evidence.year,
                                 region: evidence.region,
                                 position: evidence.position,
                                 weight: weight(year: evidence.year, currentYear: query.currentYear, oldestYear: oldestYear))
        }
        lists.sort(by: listOrder)
        let undated: Int = lists.filter { $0.year == nil }.count
        let totalWeight: Double = lists.reduce(0) { $0 + $1.weight }
        var weightByKey: [String: Double] = [:]
        for list in lists { weightByKey[list.id] = list.weight }

        // 5. Per excerpt.
        var keysByExcerpt: [String: Set<String>] = [:]
        for row in scoped {
            keysByExcerpt[row.excerptId, default: []].insert(row.key)
        }
        let yearSpan: ClosedRange<Int>? = {
            let years: [Int] = lists.compactMap { $0.year }
            guard let low = years.min(), let high = years.max() else { return nil }
            return low...high
        }()
        var items: [ExcerptAsk] = keysByExcerpt.map { (excerptId: String, keys: Set<String>) -> ExcerptAsk in
            let hits: Double = keys.reduce(0) { $0 + (weightByKey[$1] ?? 0) }
            let share: Double = totalWeight > 0 ? min(1, hits / totalWeight) : 0
            return ExcerptAsk(excerptId: excerptId,
                              listCount: keys.count,
                              totalLists: lists.count,
                              share: share,
                              tier: tier(share: share, totalLists: lists.count),
                              evidence: evidenceText(listCount: keys.count, totalLists: lists.count,
                                                     instrument: query.instrument, position: query.position,
                                                     includeAllChairs: query.includeAllChairs, years: yearSpan))
        }
        items.sort(by: askOrder)

        return LocalRecommendationResult(query: query,
                                         lists: lists,
                                         fellBackToAllRegions: fellBack,
                                         undatedLists: undated,
                                         oldestYear: oldestYear,
                                         listsWithoutChair: skippedChairKeys.count,
                                         items: items)
    }

    /// Most asked first: share, then plain count, then id (stable).
    static func askOrder(_ a: ExcerptAsk, _ b: ExcerptAsk) -> Bool {
        if a.share != b.share { return a.share > b.share }
        if a.listCount != b.listCount { return a.listCount > b.listCount }
        return a.excerptId < b.excerptId
    }

    /// Newest first; lists without a year last; then orchestra, then source.
    private static func listOrder(_ a: CollectedList, _ b: CollectedList) -> Bool {
        switch (a.year, b.year) {
        case let (x?, y?):
            if x != y { return x > y }
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            break
        }
        let orchestraA: String = a.orchestra ?? ""
        let orchestraB: String = b.orchestra ?? ""
        if orchestraA != orchestraB { return orchestraA < orchestraB }
        return a.source < b.source
    }

    // MARK: Words

    /// "cello", "double bass", "E♭ clarinet" — the instrument as it reads mid-sentence.
    static func instrumentWords(_ instrument: Instrument) -> String {
        let name: String = instrument.displayName
        if name.hasPrefix("E♭") { return name }
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// "section cello lists", "principal horn list", "cello lists" (all chairs).
    static func listsPhrase(count: Int, instrument: Instrument, position: Position, includeAllChairs: Bool) -> String {
        let noun: String = count == 1 ? String(localized: "list") : String(localized: "lists")
        let words: String = instrumentWords(instrument)
        if includeAllChairs || position == .any {
            return "\(words) \(noun)"
        }
        return "\(position.displayName.lowercased()) \(words) \(noun)"
    }

    /// " (2022–2026)", " (2025)" or "".
    static func yearsSuffix(_ years: ClosedRange<Int>?) -> String {
        guard let years = years else { return "" }
        if years.lowerBound == years.upperBound { return " (\(years.lowerBound))" }
        return " (\(years.lowerBound)\u{2013}\(years.upperBound))"
    }

    /// The plain-words line under a count. Only the numbers vary; nothing is inferred.
    ///
    /// "On 7 of the 9 section cello lists we've collected (2022–2026)"
    /// "On 3 of the 4 cello lists we've collected, all chairs (2024–2026)"
    /// "Not on any of the 9 section cello lists we've collected (2022–2026)"
    /// "We haven't collected any section cello lists yet."
    static func evidenceText(listCount: Int, totalLists: Int, instrument: Instrument, position: Position,
                             includeAllChairs: Bool, years: ClosedRange<Int>?) -> String {
        let allChairs: Bool = includeAllChairs || position == .any
        let phrase: String = listsPhrase(count: totalLists, instrument: instrument, position: position, includeAllChairs: allChairs)
        let chairs: String = allChairs ? String(localized: ", all chairs") : ""
        let when: String = yearsSuffix(years)
        if totalLists <= 0 {
            return String(localized: "We haven't collected any \(phrase) yet.")
        }
        if listCount > 0 {
            if totalLists == 1 {
                return String(localized: "On the only \(phrase) we've collected\(chairs)\(when)")
            }
            return String(localized: "On \(listCount) of the \(totalLists) \(phrase) we've collected\(chairs)\(when)")
        }
        if totalLists == 1 {
            return String(localized: "Not on the only \(phrase) we've collected\(chairs)\(when)")
        }
        return String(localized: "Not on any of the \(totalLists) \(phrase) we've collected\(chairs)\(when)")
    }

    /// "Not enough lists yet to name a tier — we have 3, we need 5." or `nil`.
    static func notEnoughListsNote(totalLists: Int) -> String? {
        guard totalLists > 0, totalLists < minimumLists else { return nil }
        return String(localized: "Not enough lists yet to name a tier — we have \(totalLists), we need \(minimumLists).")
    }

    /// Caveats shown once under a list of counts.
    static func notes(for result: LocalRecommendationResult) -> [String] {
        var out: [String] = []
        let query: RecommendationQuery = result.query
        let phrase: String = listsPhrase(count: 2, instrument: query.instrument, position: query.position,
                                         includeAllChairs: query.includeAllChairs)
        if let region = query.region {
            let regionName: String = ProfileOptions.regionName(id: region)
            if result.fellBackToAllRegions {
                out.append(String(localized: "Fewer than \(minimumLists) \(phrase) from \(regionName) so far, so this counts lists from every region."))
            } else {
                out.append(String(localized: "Counting lists from \(regionName)."))
            }
        } else {
            out.append(String(localized: "Counting lists from every region."))
        }
        if result.undatedLists > 0 {
            if let oldest = result.oldestYear {
                if result.undatedLists == 1 {
                    out.append(String(localized: "1 of these lists has no date and counts as the oldest year we have (\(oldest))."))
                } else {
                    out.append(String(localized: "\(result.undatedLists) of these lists have no date and count as the oldest year we have (\(oldest))."))
                }
            } else {
                out.append(String(localized: "None of these lists has a date, so they all count the same."))
            }
        }
        if result.listsWithoutChair > 0 && !query.includeAllChairs {
            if result.listsWithoutChair == 1 {
                out.append(String(localized: "1 more list doesn't say which chair it was for. Turn on Include all chairs to count it."))
            } else {
                out.append(String(localized: "\(result.listsWithoutChair) more lists don't say which chair they were for. Turn on Include all chairs to count them."))
            }
        }
        return out
    }
}

// MARK: - Settings

enum RecommendationSettings {
    /// UserDefaults key (Bool, default false): count lists for every chair, not only the player's.
    static let includeAllChairsKey: String = "recommendations.includeAllChairs"

    /// The query for the player's profile as stored in Settings.
    static func query(instrument: Instrument, positionRaw: String, region: String, includeAllChairs: Bool,
                      includeDrafts: Bool, now: Date = Date(), calendar: Calendar = .current) -> RecommendationQuery {
        let position: Position = Position(rawValue: positionRaw) ?? .section
        let trimmedRegion: String = region.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecommendationQuery(instrument: instrument,
                                   position: position,
                                   region: trimmedRegion.isEmpty ? nil : trimmedRegion,
                                   includeAllChairs: includeAllChairs,
                                   includeDrafts: includeDrafts,
                                   currentYear: calendar.component(.year, from: now))
    }
}
