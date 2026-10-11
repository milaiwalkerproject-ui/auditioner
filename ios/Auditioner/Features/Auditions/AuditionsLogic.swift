import Foundation

// Pure helpers behind the Auditions tab and "My upcoming audition" (PLAN F1–F4).
// No UI, no SwiftData queries, no notifications here, so every rule can be unit-tested.
// Nothing in this file knows a musical fact: it only arranges what the lists and the
// catalogue say.

// MARK: - List completeness

/// How much of the repertoire the orchestra published (mirrors `vacancies.list_completeness`).
enum ListCompleteness: String, CaseIterable, Identifiable {
    case full
    case partialPublic = "partial_public"
    case worksOnly = "works_only"
    case revealedOnInvitation = "revealed_on_invitation"
    case unknown

    var id: String { rawValue }

    init(raw: String) {
        self = ListCompleteness(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .unknown
    }

    /// Short pill text; `nil` when nothing is known (then no pill is shown).
    var badgeText: String? {
        switch self {
        case .full: return String(localized: "Full list")
        case .partialPublic: return String(localized: "Partial list — more sent to invited candidates")
        case .worksOnly: return String(localized: "Works only")
        case .revealedOnInvitation: return String(localized: "List sent with invitation")
        case .unknown: return nil
        }
    }

    /// Plain-words note for the detail screens; `nil` when nothing is known.
    var note: String? {
        switch self {
        case .full:
            return String(localized: "The orchestra published the whole list.")
        case .partialPublic:
            return String(localized: "The orchestra published part of the list. The rest is sent to invited candidates — check your invitation.")
        case .worksOnly:
            return String(localized: "The orchestra named the works but not the passages. Check the official list for the bars.")
        case .revealedOnInvitation:
            return String(localized: "The list is sent with the invitation. Add it here when it arrives.")
        case .unknown:
            return nil
        }
    }

    /// Name in the edit form.
    var displayName: String {
        switch self {
        case .full: return String(localized: "Full list")
        case .partialPublic: return String(localized: "Partial list")
        case .worksOnly: return String(localized: "Works only")
        case .revealedOnInvitation: return String(localized: "Sent with invitation")
        case .unknown: return String(localized: "Not sure")
        }
    }
}

// MARK: - Countdown

enum AuditionCountdown {
    /// Whole calendar days from `now` to `target` (negative when the day has passed).
    static func days(from now: Date, to target: Date, calendar: Calendar) -> Int {
        let start: Date = calendar.startOfDay(for: now)
        let end: Date = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// "in 12 days", "tomorrow", "today", "yesterday", "3 days ago" — mid-sentence form.
    static func phrase(days: Int) -> String {
        if days == 0 { return String(localized: "today") }
        if days == 1 { return String(localized: "tomorrow") }
        if days == -1 { return String(localized: "yesterday") }
        if days > 1 { return String(localized: "in \(days) days") }
        return String(localized: "\(-days) days ago")
    }

    static func phrase(to target: Date, now: Date, calendar: Calendar) -> String {
        phrase(days: days(from: now, to: target, calendar: calendar))
    }

    /// "In 12 days" — for the start of a line.
    static func capitalized(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return String(first).uppercased() + String(phrase.dropFirst())
    }

    static func isPast(days: Int) -> Bool {
        days < 0
    }
}

// MARK: - Readiness

/// Readiness is the player's own 1 (not started) … 5 (audition-ready) rating per item.
enum AuditionReadiness {
    /// Ratings of 4 and 5 count as "ready" for the ring.
    static let readyThreshold: Int = 4

    static func clamp(_ rating: Int?) -> Int? {
        guard let rating = rating else { return nil }
        return min(5, max(1, rating))
    }

    static func isReady(_ rating: Int?) -> Bool {
        guard let rating = rating else { return false }
        return rating >= readyThreshold
    }

    static func readyCount(_ ratings: [Int?]) -> Int {
        ratings.filter { isReady($0) }.count
    }

    /// Share of items rated 4–5, 0…1; 0 when the list is empty.
    static func share(_ ratings: [Int?]) -> Double {
        guard !ratings.isEmpty else { return 0 }
        return Double(readyCount(ratings)) / Double(ratings.count)
    }

    /// "3 of 8 ready", "No items yet".
    static func label(_ ratings: [Int?]) -> String {
        if ratings.isEmpty { return String(localized: "No items yet") }
        return String(localized: "\(readyCount(ratings)) of \(ratings.count) ready")
    }

    /// Short word for one rating, shown next to the stars.
    static func word(for rating: Int?) -> String {
        switch rating {
        case 1: return String(localized: "Not started")
        case 2: return String(localized: "Learning the notes")
        case 3: return String(localized: "Under tempo")
        case 4: return String(localized: "Nearly there")
        case 5: return String(localized: "Audition-ready")
        default: return String(localized: "Not rated yet")
        }
    }
}

// MARK: - Rounds

enum AuditionRounds {
    static let preliminary: String = "Preliminary"
    static let semiFinal: String = "Semi-final"
    static let finalRound: String = "Final"

    /// The three usual rounds, for pickers. "" means the list doesn't split rounds.
    static let choices: [String] = ["", preliminary, semiFinal, finalRound]

    /// Maps what a list (or the crawler) prints to one of the three canonical names when it clearly is one;
    /// "All rounds" and blanks become "" (applies everywhere); anything else is kept as typed.
    static func canonical(_ round: String) -> String {
        let trimmed: String = round.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if key.isEmpty || key == "all rounds" || key == "all" || key == "every round" { return "" }
        if key == "preliminary" || key == "preliminaries" || key == "prelim" || key == "prelims"
            || key == "preliminary round" || key == "first round" || key == "round 1" || key == "round one" {
            return preliminary
        }
        if key == "semi final" || key == "semifinal" || key == "semi finals" || key == "semifinals"
            || key == "semi final round" || key == "second round" || key == "round 2" || key == "round two" {
            return semiFinal
        }
        if key == "final" || key == "finals" || key == "final round" || key == "third round" || key == "round 3" || key == "round three" {
            return finalRound
        }
        return trimmed
    }

    /// Sort rank: unspecified first (it applies to every round), then preliminary, semi-final, final, then anything else.
    static func rank(_ round: String) -> Int {
        let name: String = canonical(round)
        if name.isEmpty { return 0 }
        if name == preliminary { return 1 }
        if name == semiFinal { return 2 }
        if name == finalRound { return 3 }
        return 4
    }

    /// Section header words. "" → "All rounds".
    static func displayName(_ round: String) -> String {
        let name: String = canonical(round)
        if name.isEmpty { return String(localized: "All rounds") }
        if name == preliminary { return String(localized: "Preliminary round") }
        if name == semiFinal { return String(localized: "Semi-final") }
        if name == finalRound { return String(localized: "Final round") }
        return name
    }
}

// MARK: - Categories

/// What kind of line it is (mirrors `vacancy_items.category`).
enum AuditionItemCategory: String, CaseIterable, Identifiable {
    case solo
    case excerpt
    case sightReading = "sight_reading"
    case chamber
    case other

    var id: String { rawValue }

    init(raw: String) {
        self = AuditionItemCategory(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .other
    }

    var displayName: String {
        switch self {
        case .solo: return String(localized: "Solo")
        case .excerpt: return String(localized: "Orchestral excerpts")
        case .sightReading: return String(localized: "Sight-reading")
        case .chamber: return String(localized: "Chamber music")
        case .other: return String(localized: "Other")
        }
    }

    /// Order inside a round: solo first, then excerpts, chamber, sight-reading, other.
    var rank: Int {
        switch self {
        case .solo: return 0
        case .excerpt: return 1
        case .chamber: return 2
        case .sightReading: return 3
        case .other: return 4
        }
    }

    /// Sight-reading cannot be practised in advance, so it stays out of the practice plan and mock auditions.
    var isPractisable: Bool {
        self != .sightReading
    }
}

// MARK: - Grouping

/// One section of the checklist: a round and a category.
struct AuditionItemGroup<Item>: Identifiable {
    let round: String
    let category: AuditionItemCategory
    var items: [Item]

    var id: String { round + "|" + category.rawValue }

    /// "Preliminary round · Orchestral excerpts", or just the category when the list has no rounds.
    func title(showRound: Bool) -> String {
        if showRound {
            return String(localized: "\(AuditionRounds.displayName(round)) · \(category.displayName)")
        }
        return category.displayName
    }
}

enum AuditionItemGrouping {
    /// Groups by round (in round order) then category (in category order); items keep their own order inside.
    static func groups<Item>(_ items: [Item],
                             round: (Item) -> String,
                             category: (Item) -> String,
                             order: (Item) -> Int) -> [AuditionItemGroup<Item>] {
        var result: [AuditionItemGroup<Item>] = []
        for item in items {
            let roundName: String = AuditionRounds.canonical(round(item))
            let cat: AuditionItemCategory = AuditionItemCategory(raw: category(item))
            if let index = result.firstIndex(where: { $0.round == roundName && $0.category == cat }) {
                result[index].items.append(item)
            } else {
                result.append(AuditionItemGroup(round: roundName, category: cat, items: [item]))
            }
        }
        for index in result.indices {
            result[index].items.sort { order($0) < order($1) }
        }
        result.sort { a, b in
            let ra: Int = AuditionRounds.rank(a.round)
            let rb: Int = AuditionRounds.rank(b.round)
            if ra != rb { return ra < rb }
            if a.round != b.round { return a.round < b.round }
            return a.category.rank < b.category.rank
        }
        return result
    }

    /// Round names are only worth showing when the list has more than one.
    static func showsRounds<Item>(_ groups: [AuditionItemGroup<Item>]) -> Bool {
        Set(groups.map { $0.round }).count > 1
    }
}

// MARK: - Practice plan

/// What the plan needs to know about one item (kept free of SwiftData so it can be tested).
struct PracticePlanCandidate: Equatable, Identifiable {
    var id: UUID
    var readiness: Int?
    var roundRank: Int
    var difficulty: Int?
    var order: Int
    var isPractisable: Bool = true
}

enum AuditionPracticePlan {
    /// Difficulty is used only when a reviewer approved it (honesty contract).
    static func approvedDifficulty(_ excerpt: Excerpt?) -> Int? {
        guard let difficulty = excerpt?.difficulty, difficulty.reviewStatus == .approved else { return nil }
        return difficulty.value
    }

    /// Lowest readiness first (not rated counts as 0), then the earliest round, then the harder excerpt, then list order.
    static func comesFirst(_ a: PracticePlanCandidate, _ b: PracticePlanCandidate) -> Bool {
        let ra: Int = a.readiness ?? 0
        let rb: Int = b.readiness ?? 0
        if ra != rb { return ra < rb }
        if a.roundRank != b.roundRank { return a.roundRank < b.roundRank }
        let da: Int = a.difficulty ?? 0
        let db: Int = b.difficulty ?? 0
        if da != db { return da > db }
        return a.order < b.order
    }

    static func ordered(_ items: [PracticePlanCandidate]) -> [PracticePlanCandidate] {
        items.filter { $0.isPractisable }.sorted(by: comesFirst)
    }

    /// "Practise next": the top `limit` of the ordered plan.
    static func practiseNext(_ items: [PracticePlanCandidate], limit: Int = 3) -> [PracticePlanCandidate] {
        Array(ordered(items).prefix(max(0, limit)))
    }
}

// MARK: - Dates

enum AuditionDates {
    /// "2026-11-03" (any longer ISO text is cut to its first 10 characters) → noon of that day in the calendar's time zone.
    /// Noon keeps the calendar day stable across daylight-saving changes; countdowns use whole days anyway.
    static func parseDay(_ text: String?, calendar: Calendar) -> Date? {
        guard let text = text else { return nil }
        let day: String = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        let parts: [Substring] = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              year >= 1900, (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        // Reject rolled-over days such as 2026-02-31.
        let check: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == dayOfMonth else { return nil }
        return date
    }

    /// The earliest day that parses, or `nil`.
    static func earliestDay(_ texts: [String], calendar: Calendar) -> Date? {
        texts.compactMap { parseDay($0, calendar: calendar) }.min()
    }

    /// "yyyy-MM-dd" for the day in the calendar's time zone.
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The day the way the user's locale writes it ("3 Nov 2026").
    static func dayText(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style)
    }

    /// Noon of the given day, so a date picked in the UI stores like a parsed one.
    static func noon(of date: Date, calendar: Calendar) -> Date {
        let start: Date = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .hour, value: 12, to: start) ?? date
    }
}

// MARK: - Sorting "My auditions"

enum AuditionOrdering {
    /// Auditions sort by the audition day, else the deadline, else at the end.
    static func sortDate(auditionDate: Date?, deadline: Date?) -> Date {
        if let auditionDate = auditionDate { return auditionDate }
        if let deadline = deadline { return deadline }
        return Date.distantFuture
    }
}

// MARK: - Archive (PLAN F5)

/// "Delete audition" archives; the archive offers Restore and Delete for good.
enum AuditionArchive {
    /// The "Archived (N)" row is shown only when there is something in it.
    static func showsArchivedRow(count: Int) -> Bool {
        count > 0
    }

    /// "Archived (3)" — the navigation row under "My auditions".
    static func archivedRowTitle(count: Int) -> String {
        String(localized: "Archived (\(count))")
    }

    /// Most recently archived first; two archived at the same moment keep the newer audition first.
    static func archivedFirst(_ auditions: [Audition]) -> [Audition] {
        auditions.sorted { a, b in
            let da: Date = a.archivedAt ?? a.createdAt
            let db: Date = b.archivedAt ?? b.createdAt
            if da != db { return da > db }
            return a.createdAt > b.createdAt
        }
    }
}

// MARK: - Open auditions feed

enum OpenAuditionsLogic {
    /// UserDefaults key (Bool, default false): the feed shows every region, not only the player's (PLAN F5).
    static let allRegionsKey: String = "auditions.feedAllRegions"

    static func showsAllRegions(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allRegionsKey)
    }

    static func setShowsAllRegions(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: allRegionsKey)
    }

    /// The `region` sent to `/v1/auditions`: `nil` (every region) when "All regions" is on or the
    /// player's region is blank, else the region id.
    static func feedRegion(allRegions: Bool, region: String) -> String? {
        if allRegions { return nil }
        let trimmed: String = region.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Picker choice and section subtitle: "Your region (North America)" / "All regions".
    static func scopeTitle(allRegions: Bool, regionName: String) -> String {
        if allRegions { return String(localized: "All regions") }
        return String(localized: "Your region (\(regionName))")
    }

    /// Open = no deadline we could parse, or a deadline today or later.
    static func isOpen(_ vacancy: FeedVacancy, today: Date, calendar: Calendar) -> Bool {
        guard let deadline = AuditionDates.parseDay(vacancy.applicationDeadline, calendar: calendar) else { return true }
        return calendar.startOfDay(for: deadline) >= calendar.startOfDay(for: today)
    }

    /// Open vacancies, soonest deadline first; without a deadline last; ties by orchestra name.
    static func openSorted(_ list: [FeedVacancy], today: Date, calendar: Calendar) -> [FeedVacancy] {
        let open: [FeedVacancy] = list.filter { isOpen($0, today: today, calendar: calendar) }
        return open.sorted { a, b in
            let da: Date? = AuditionDates.parseDay(a.applicationDeadline, calendar: calendar)
            let db: Date? = AuditionDates.parseDay(b.applicationDeadline, calendar: calendar)
            switch (da, db) {
            case let (x?, y?):
                if x != y { return x < y }
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case (nil, nil):
                break
            }
            let byName: ComparisonResult = a.orchestra.localizedCaseInsensitiveCompare(b.orchestra)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
    }

    /// "From <orchestra>'s website, checked 3 Nov 2026" — where the facts come from.
    static func sourceLine(orchestra: String, lastCheckedAt: String?) -> String {
        let checked: String = (lastCheckedAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if checked.isEmpty {
            return String(localized: "From \(orchestra)'s website")
        }
        return String(localized: "From \(orchestra)'s website, checked \(ExcerptFormat.displayDate(checked))")
    }

    /// The vacancy's instrument when the app knows it, else the player's own.
    static func instrument(for vacancy: FeedVacancy, fallback: Instrument) -> Instrument {
        Instrument(rawValue: vacancy.instrument) ?? fallback
    }

    /// "Audition 3 Nov 2026" / "Auditions 3 Nov 2026, 4 Nov 2026" / nil. Days that don't parse are shown as printed.
    static func auditionDatesLine(_ dates: [String], calendar: Calendar = .current) -> String? {
        let cleaned: [String] = dates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let texts: [String] = cleaned.map { text in
            if let day = AuditionDates.parseDay(text, calendar: calendar) {
                return AuditionDates.dayText(day, calendar: calendar)
            }
            return text
        }
        if texts.count == 1 {
            return String(localized: "Audition \(texts[0])")
        }
        return String(localized: "Auditions \(texts.joined(separator: ", "))")
    }
}

// MARK: - Building an audition from the feed or the catalogue

enum AuditionBuilder {
    /// A new (not yet inserted) audition with the vacancy's facts. Nothing is invented: a date that
    /// doesn't parse stays empty.
    static func audition(from vacancy: FeedVacancy, fallbackInstrument: Instrument, calendar: Calendar) -> Audition {
        let instrument: Instrument = OpenAuditionsLogic.instrument(for: vacancy, fallback: fallbackInstrument)
        let audition = Audition(orchestra: vacancy.orchestra, position: vacancy.position, instrument: instrument)
        audition.applicationDeadline = AuditionDates.parseDay(vacancy.applicationDeadline, calendar: calendar)
        audition.auditionDate = AuditionDates.earliestDay(vacancy.auditionDates, calendar: calendar)
        audition.vacancyId = vacancy.id
        audition.sourceURL = vacancy.sourceURL
        audition.listCompleteness = ListCompleteness(raw: vacancy.listCompleteness).rawValue
        return audition
    }

    /// Checklist items from the feed's items, in the feed's order. Lines without text are skipped.
    static func items(from vacancy: FeedVacancy, auditionId: UUID, startOrder: Int = 0) -> [AuditionItem] {
        var result: [AuditionItem] = []
        for feedItem in vacancy.items {
            let text: String = feedItem.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let item = AuditionItem(auditionId: auditionId, order: startOrder + result.count, rawText: text)
            item.category = AuditionItemCategory(raw: feedItem.category).rawValue
            item.round = AuditionRounds.canonical(feedItem.round)
            item.excerptId = cleanExcerptId(feedItem.excerptId)
            result.append(item)
        }
        return result
    }

    /// "Strauss · Don Juan — Opening": the line used when an item is added from the catalogue.
    static func itemTitle(for excerpt: Excerpt) -> String {
        "\(excerpt.workHeading) — \(excerpt.subtitle)"
    }

    static func item(for excerpt: Excerpt, auditionId: UUID, order: Int, round: String = "") -> AuditionItem {
        let item = AuditionItem(auditionId: auditionId, order: order, rawText: itemTitle(for: excerpt))
        item.excerptId = excerpt.id
        item.category = AuditionItemCategory.excerpt.rawValue
        item.round = AuditionRounds.canonical(round)
        return item
    }

    static func cleanExcerptId(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Order for a new item appended after the existing ones.
    static func nextOrder(existingOrders: [Int]) -> Int {
        (existingOrders.max() ?? -1) + 1
    }

    /// The `order` values after moving rows inside one section: the same set of values, handed out in the new sequence,
    /// so the section keeps its place among the others.
    static func reorderedOrders(_ orders: [Int], from source: IndexSet, to destination: Int) -> [Int] {
        let indices: [Int] = moved(Array(orders.indices), from: source, to: destination)
        let slots: [Int] = orders.sorted()
        var result: [Int] = Array(repeating: 0, count: orders.count)
        for (slot, originalIndex) in indices.enumerated() where slot < slots.count {
            result[originalIndex] = slots[slot]
        }
        return result
    }

    /// The same move a SwiftUI list performs (`move(fromOffsets:toOffset:)`), written out here so this file needs
    /// only Foundation: the picked elements, in their old order, are put back in front of the element that sat at
    /// `destination` before the move. Offsets outside the array are ignored.
    static func moved<Element>(_ array: [Element], from source: IndexSet, to destination: Int) -> [Element] {
        let picked: [Int] = Array(source).filter { $0 >= 0 && $0 < array.count }
        guard !picked.isEmpty else { return array }
        let pickedSet: Set<Int> = Set(picked)
        let moving: [Element] = picked.map { array[$0] }
        var remaining: [Element] = []
        for (index, element) in array.enumerated() where !pickedSet.contains(index) {
            remaining.append(element)
        }
        let removedBefore: Int = picked.filter { $0 < destination }.count
        let insertAt: Int = min(max(0, destination - removedBefore), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}

// MARK: - Tempo fields

enum AuditionTempo {
    static let minBPM: Double = 20
    static let maxBPM: Double = 400

    /// What the player typed → a BPM, or `nil` for blank / nonsense. Clamped to a sane range.
    static func parse(_ text: String) -> Double? {
        let cleaned: String = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return min(maxBPM, max(minBPM, value))
    }

    static func text(_ bpm: Double?) -> String {
        guard let bpm = bpm else { return "" }
        return TempoSymbols.bpmText(bpm)
    }

    /// "♩ 72 → 96" summary for a row; `nil` when neither tempo is set.
    static func summary(target: Double?, achieved: Double?) -> String? {
        switch (achieved, target) {
        case (nil, nil):
            return nil
        case let (a?, t?):
            return String(localized: "At \(TempoSymbols.bpmText(a)), aiming for \(TempoSymbols.bpmText(t))")
        case let (a?, nil):
            return String(localized: "At \(TempoSymbols.bpmText(a))")
        case let (nil, t?):
            return String(localized: "Aiming for \(TempoSymbols.bpmText(t))")
        }
    }
}
