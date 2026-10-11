import Foundation

// MARK: - ISO weeks

/// "YYYY-Www" ISO week ids, reckoned in UTC like the server (backend/app/trends.py accepts only
/// this week and last week, UTC). The calendar is injectable so tests can move the time zone.
enum TrendsWeek {
    /// ISO 8601 weeks (Monday first; week 1 is the week with 4 January) in UTC.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        if let utc = TimeZone(identifier: "UTC") {
            calendar.timeZone = utc
        } else if let zero = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = zero
        }
        return calendar
    }()

    /// ISO week rules in the time zone of `calendar` (any identifier).
    private static func isoCalendar(like calendar: Calendar) -> Calendar {
        if calendar.identifier == .iso8601 { return calendar }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso
    }

    /// The ISO week `date` falls in, e.g. "2026-W41". Around New Year the ISO year differs from
    /// the calendar year: 2027-01-01 is in 2026-W53.
    static func id(for date: Date, calendar: Calendar = TrendsWeek.utcCalendar) -> String {
        let iso: Calendar = isoCalendar(like: calendar)
        let year: Int = iso.component(.yearForWeekOfYear, from: date)
        let week: Int = iso.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    /// The week before the one `date` falls in.
    static func previousId(for date: Date, calendar: Calendar = TrendsWeek.utcCalendar) -> String {
        let iso: Calendar = isoCalendar(like: calendar)
        let earlier: Date = iso.date(byAdding: .day, value: -7, to: date) ?? date.addingTimeInterval(-7 * 86_400)
        return id(for: earlier, calendar: iso)
    }

    /// True for ids shaped "YYYY-Www" with a week number 01…53 (the shape the server expects).
    static func isValidId(_ id: String) -> Bool {
        let parts: [Substring] = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let year: Substring = parts[0]
        let week: Substring = parts[1]
        guard year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        guard week.count == 3, week.first == "W" else { return false }
        let digits: Substring = week.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { return false }
        return (1...53).contains(number)
    }
}

// MARK: - Stored sets

/// The catalogue excerpts practised in one ISO week on one instrument: what one POST carries.
struct TrendsWeekSet: Codable, Hashable {
    /// `Instrument.rawValue`.
    var instrument: String
    /// "YYYY-Www".
    var week: String
    /// Sorted, no repeats, at most `TrendsTracker.maxExcerptsPerWeek`.
    var excerptIds: [String]
}

/// Remembers which catalogue excerpts were practised this ISO week, per instrument — and only
/// while sharing is on (PLAN D6: opt-in, off by default). Kept in UserDefaults; `TrendsUploader`
/// posts and prunes the sets. Safe to call from any thread.
final class TrendsTracker {
    static let shared = TrendsTracker()

    /// The server accepts at most 50 excerpt ids for one week.
    static let maxExcerptsPerWeek: Int = 50
    /// UserDefaults key: JSON `[TrendsWeekSet]`.
    static let storageKey: String = "trends.practised"

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard,
         calendar: Calendar = TrendsWeek.utcCalendar,
         now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    /// Call when the player practised a catalogue excerpt: playback started, a take was saved, a mock
    /// audition finished. Does nothing while sharing is off, for `nil`, or for ids that aren't
    /// catalogue-shaped (`TrendsLogic.cleanExcerptId`). Never pass text the player typed.
    func notePractised(excerptId: String?, instrument: Instrument) {
        guard let excerptId = excerptId else { return }
        notePractised(excerptIds: [excerptId], instrument: instrument)
    }

    /// Same, for several excerpts at once (a mock audition run).
    func notePractised(excerptIds: [String], instrument: Instrument) {
        let cleaned: [String] = excerptIds.compactMap { TrendsLogic.cleanExcerptId($0) }
        guard !cleaned.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard defaults.bool(forKey: TrendsSettings.sharingKey) else { return }
        let week: String = TrendsWeek.id(for: now(), calendar: calendar)
        var sets: [TrendsWeekSet] = loadLocked()
        let index: Int
        if let existing = sets.firstIndex(where: { $0.instrument == instrument.rawValue && $0.week == week }) {
            index = existing
        } else {
            sets.append(TrendsWeekSet(instrument: instrument.rawValue, week: week, excerptIds: []))
            index = sets.count - 1
        }
        var ids: Set<String> = Set(sets[index].excerptIds)
        for id in cleaned where ids.count < TrendsTracker.maxExcerptsPerWeek {
            ids.insert(id)
        }
        sets[index].excerptIds = ids.sorted()
        saveLocked(sets)
    }

    /// Every stored week set (any instrument, any week), oldest first.
    func sets() -> [TrendsWeekSet] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func excerptIds(instrument: Instrument, week: String) -> [String] {
        sets().first { $0.instrument == instrument.rawValue && $0.week == week }?.excerptIds ?? []
    }

    /// Forgets one week set (after its final upload).
    func remove(instrument: String, week: String) {
        lock.lock()
        defer { lock.unlock() }
        let kept: [TrendsWeekSet] = loadLocked().filter { !($0.instrument == instrument && $0.week == week) }
        saveLocked(kept)
    }

    /// Drops the weeks the server would no longer accept.
    func prune(keepingWeeks weeks: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        saveLocked(loadLocked().filter { weeks.contains($0.week) })
    }

    /// Forgets everything (sharing turned off).
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: TrendsTracker.storageKey)
    }

    // MARK: Storage (call with the lock held)

    private func loadLocked() -> [TrendsWeekSet] {
        guard let data = defaults.data(forKey: TrendsTracker.storageKey) else { return [] }
        let decoded: [TrendsWeekSet] = (try? JSONDecoder().decode([TrendsWeekSet].self, from: data)) ?? []
        return decoded.filter { TrendsWeek.isValidId($0.week) && Instrument(rawValue: $0.instrument) != nil }
    }

    private func saveLocked(_ sets: [TrendsWeekSet]) {
        if sets.isEmpty {
            defaults.removeObject(forKey: TrendsTracker.storageKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(sets) {
            defaults.set(data, forKey: TrendsTracker.storageKey)
        }
    }
}
