import XCTest
@testable import Auditioner

/// "Popular with other players" (PLAN D6). Synthetic ids and fictional fixtures only; the clock,
/// the calendar, UserDefaults and the network are all injected.
final class TrendsTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TrendsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            XCTFail("bad test date \(year)-\(month)-\(day)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    private func excerpt(_ id: String, instrument: Instrument = .cello) -> Excerpt {
        Excerpt(id: id,
                instrument: instrument,
                positions: [.section],
                composer: "Example Composer",
                work: "Example Work",
                title: id,
                location: Verifiable<ExcerptLocation>.unverified,
                sources: [],
                listingStatus: .published)
    }

    private func response(enough: Bool = true, _ entries: [(String, String)]) -> TrendsResponse {
        TrendsResponse(enough: enough, fromWeek: "2026-W34", toWeek: "2026-W41",
                       trends: entries.map { TrendsResponseEntry(excerptId: $0.0, tier: $0.1) })
    }

    /// Records every call; can fail chosen weeks, the delete, or the GET.
    private final class FakeTrendsAPI: TrendsAPI {
        var isConfigured: Bool = true
        var shared: [(instrument: Instrument, week: String, excerptIds: [String])] = []
        var failingWeeks: Set<String> = []
        var deleteCalls: Int = 0
        var deleteFails: Bool = false
        var trendsCalls: Int = 0
        var answer: TrendsResponse = TrendsResponse(enough: false, fromWeek: "2026-W34", toWeek: "2026-W41", trends: [])
        var trendsError: Error? = nil

        func shareTrends(instrument: Instrument, week: String, excerptIds: [String]) async throws {
            if failingWeeks.contains(week) { throw APIError.server(status: 502, message: "down") }
            shared.append((instrument: instrument, week: week, excerptIds: excerptIds))
        }

        func forgetTrends() async throws {
            deleteCalls += 1
            if deleteFails { throw APIError.server(status: 502, message: "down") }
        }

        func trends(instrument: Instrument) async throws -> TrendsResponse {
            trendsCalls += 1
            if let error = trendsError { throw error }
            return answer
        }
    }

    // MARK: ISO weeks

    func testISOWeekIdsAcrossYearBoundaries() {
        // 2026 has 53 ISO weeks (1 January 2026 is a Thursday).
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2026, 12, 31)), "2026-W53")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2027, 1, 1)), "2026-W53", "New Year's Day still belongs to 2026's last week")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2027, 1, 3)), "2026-W53")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2027, 1, 4)), "2027-W01")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2026, 1, 1)), "2026-W01")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2025, 12, 29)), "2026-W01", "the Monday before New Year opens 2026-W01")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2025, 12, 28)), "2025-W52")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2026, 10, 11)), "2026-W41")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2026, 10, 12)), "2026-W42")
        XCTAssertEqual(TrendsWeek.id(for: utcDate(2021, 1, 1)), "2020-W53")
    }

    func testPreviousWeekId() {
        XCTAssertEqual(TrendsWeek.previousId(for: utcDate(2027, 1, 4)), "2026-W53")
        XCTAssertEqual(TrendsWeek.previousId(for: utcDate(2026, 1, 1)), "2025-W52")
        XCTAssertEqual(TrendsWeek.previousId(for: utcDate(2026, 10, 12)), "2026-W41")
        XCTAssertEqual(TrendsWeek.previousId(for: utcDate(2026, 10, 11)), "2026-W40")
    }

    func testWeekFollowsTheInjectedCalendar() {
        // Sunday 23:30 UTC is already Monday in Auckland (UTC+13 in October).
        let lateSunday: Date = utcDate(2026, 10, 11, hour: 23, minute: 30)
        XCTAssertEqual(TrendsWeek.id(for: lateSunday), "2026-W41")
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland") ?? auckland.timeZone
        XCTAssertEqual(TrendsWeek.id(for: lateSunday, calendar: auckland), "2026-W42")
        XCTAssertEqual(TrendsWeek.previousId(for: lateSunday, calendar: auckland), "2026-W41")
    }

    func testWeekIdShape() {
        XCTAssertTrue(TrendsWeek.isValidId("2026-W41"))
        XCTAssertTrue(TrendsWeek.isValidId("2026-W53"))
        XCTAssertTrue(TrendsWeek.isValidId("2027-W01"))
        XCTAssertFalse(TrendsWeek.isValidId("2026-W00"))
        XCTAssertFalse(TrendsWeek.isValidId("2026-W54"))
        XCTAssertFalse(TrendsWeek.isValidId("2026-41"))
        XCTAssertFalse(TrendsWeek.isValidId("26-W41"))
        XCTAssertFalse(TrendsWeek.isValidId("2026-w41"))
        XCTAssertFalse(TrendsWeek.isValidId("2026-W4"))
        XCTAssertFalse(TrendsWeek.isValidId(""))
    }

    // MARK: Tracker

    func testTrackerRecordsOnlyWhileSharingIsOn() {
        let tracker = TrendsTracker(defaults: defaults, now: { self.utcDate(2026, 10, 7) })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        XCTAssertTrue(tracker.sets().isEmpty, "sharing is off by default: nothing is remembered")

        defaults.set(true, forKey: TrendsSettings.sharingKey)
        tracker.notePractised(excerptId: "ex-b", instrument: .cello)
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        tracker.notePractised(excerptId: nil, instrument: .cello)
        tracker.notePractised(excerptId: "   ", instrument: .cello)
        tracker.notePractised(excerptId: "typed by the player", instrument: .cello)
        tracker.notePractised(excerptId: " ex-c ", instrument: .cello)
        XCTAssertEqual(tracker.excerptIds(instrument: .cello, week: "2026-W41"), ["ex-a", "ex-b", "ex-c"], "sorted, no repeats, trimmed")
        XCTAssertEqual(tracker.sets().count, 1)

        tracker.notePractised(excerptIds: ["v-1", "v-2"], instrument: .viola)
        XCTAssertEqual(tracker.sets().count, 2, "one set per instrument and week")
        XCTAssertEqual(tracker.excerptIds(instrument: .viola, week: "2026-W41"), ["v-1", "v-2"])

        defaults.set(false, forKey: TrendsSettings.sharingKey)
        tracker.notePractised(excerptId: "ex-d", instrument: .cello)
        XCTAssertEqual(tracker.excerptIds(instrument: .cello, week: "2026-W41"), ["ex-a", "ex-b", "ex-c"], "nothing is added once sharing is off")
    }

    func testTrackerCapsAtFiftyAndKeepsWeeksApart() {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let many: [String] = (1...60).map { String(format: "ex-%03d", $0) }
        tracker.notePractised(excerptIds: many, instrument: .cello)
        XCTAssertEqual(tracker.excerptIds(instrument: .cello, week: "2026-W41").count, TrendsTracker.maxExcerptsPerWeek)

        clock = utcDate(2026, 10, 13)
        tracker.notePractised(excerptId: "ex-new", instrument: .cello)
        XCTAssertEqual(tracker.excerptIds(instrument: .cello, week: "2026-W42"), ["ex-new"])
        XCTAssertEqual(tracker.sets().map { $0.week }, ["2026-W41", "2026-W42"])

        tracker.prune(keepingWeeks: ["2026-W42"])
        XCTAssertEqual(tracker.sets().map { $0.week }, ["2026-W42"])
        tracker.remove(instrument: Instrument.cello.rawValue, week: "2026-W42")
        XCTAssertTrue(tracker.sets().isEmpty)

        tracker.notePractised(excerptId: "ex-x", instrument: .cello)
        tracker.clearAll()
        XCTAssertTrue(tracker.sets().isEmpty)
        XCTAssertNil(defaults.data(forKey: TrendsTracker.storageKey))
    }

    func testCleanExcerptId() {
        XCTAssertEqual(TrendsLogic.cleanExcerptId("  mahler-5-cello-1 "), "mahler-5-cello-1")
        XCTAssertNil(TrendsLogic.cleanExcerptId(""))
        XCTAssertNil(TrendsLogic.cleanExcerptId("   "))
        XCTAssertNil(TrendsLogic.cleanExcerptId("has a space"))
        XCTAssertNil(TrendsLogic.cleanExcerptId(String(repeating: "x", count: 129)))
        XCTAssertNotNil(TrendsLogic.cleanExcerptId(String(repeating: "x", count: 128)))
    }

    // MARK: Uploader

    @MainActor
    func testUploaderPostsThisWeekAndLastWeeksFinalSetOnce() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = FakeTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })

        tracker.notePractised(excerptIds: ["ex-b", "ex-a"], instrument: .cello)
        clock = utcDate(2026, 10, 13)
        tracker.notePractised(excerptId: "ex-c", instrument: .cello)

        let first: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(first, .sent(2))
        XCTAssertEqual(api.shared.map { $0.week }, ["2026-W41", "2026-W42"])
        XCTAssertEqual(api.shared[0].excerptIds, ["ex-a", "ex-b"])
        XCTAssertEqual(api.shared[1].excerptIds, ["ex-c"])
        XCTAssertEqual(api.shared[0].instrument, .cello)
        XCTAssertEqual(tracker.sets().map { $0.week }, ["2026-W42"], "last week's final set is forgotten after its upload")
        XCTAssertEqual(uploader.lastUploadAt, clock)

        clock = clock.addingTimeInterval(13 * 3600)
        let second: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(second, .sent(1))
        XCTAssertEqual(api.shared.count, 3)
        XCTAssertEqual(api.shared[2].week, "2026-W42", "last week is not posted again")
    }

    @MainActor
    func testUploaderThrottlesToOncePerTwelveHours() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = FakeTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)

        let first: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(first, .sent(1))
        clock = clock.addingTimeInterval(3600)
        let soon: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(soon, .throttled)
        XCTAssertEqual(api.shared.count, 1)
        clock = clock.addingTimeInterval(11 * 3600 - 1)
        let almost: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(almost, .throttled)
        clock = clock.addingTimeInterval(2)
        let later: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(later, .sent(1))
        XCTAssertEqual(api.shared.count, 2)

        // A clock that went backwards (still inside the same week) never blocks for good.
        clock = clock.addingTimeInterval(-5 * 3600)
        let earlier: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(earlier, .sent(1))
    }

    @MainActor
    func testUploaderSkipsWhenSharingIsOffOrThereIsNoServer() async {
        let clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = FakeTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })

        let off: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(off, .sharingOff)

        defaults.set(true, forKey: TrendsSettings.sharingKey)
        api.isConfigured = false
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        let noServer: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(noServer, .noServer)
        XCTAssertNil(uploader.lastUploadAt, "a skipped sync doesn't use up the 12-hour slot")

        api.isConfigured = true
        tracker.clearAll()
        let empty: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(empty, .nothingToSend)
        XCTAssertTrue(api.shared.isEmpty)
        XCTAssertNil(uploader.lastUploadAt)
    }

    @MainActor
    func testUploaderDropsWeeksTheServerWouldRefuseAndRetriesFailures() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 9, 23) // 2026-W39
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = FakeTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-old", instrument: .cello)
        clock = utcDate(2026, 10, 1) // 2026-W40
        tracker.notePractised(excerptId: "ex-last", instrument: .cello)
        clock = utcDate(2026, 10, 7) // 2026-W41
        tracker.notePractised(excerptId: "ex-now", instrument: .cello)

        api.failingWeeks = ["2026-W40"]
        let first: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(first, .failed(sent: 1, failed: 1))
        XCTAssertEqual(api.shared.map { $0.week }, ["2026-W41"])
        XCTAssertEqual(tracker.sets().map { $0.week }, ["2026-W40", "2026-W41"], "two weeks ago is dropped; the failed final set stays")

        api.failingWeeks = []
        clock = clock.addingTimeInterval(13 * 3600)
        let second: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(second, .sent(2))
        XCTAssertEqual(api.shared.map { $0.week }, ["2026-W41", "2026-W40", "2026-W41"])
        XCTAssertEqual(tracker.sets().map { $0.week }, ["2026-W41"])
    }

    @MainActor
    func testTurningSharingOffDeletesWhatWasSharedAndClearsTheDevice() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = FakeTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        _ = await uploader.sync()
        XCTAssertNotNil(uploader.lastUploadAt)

        defaults.set(false, forKey: TrendsSettings.sharingKey)
        api.deleteFails = true
        await uploader.sharingTurnedOff()
        XCTAssertTrue(tracker.sets().isEmpty, "local sets go at once")
        XCTAssertEqual(api.deleteCalls, 1)
        XCTAssertTrue(uploader.hasPendingDelete, "the delete is still owed")
        XCTAssertNil(uploader.lastUploadAt)

        // Next launch: the delete is tried again before anything else, and nothing is uploaded meanwhile.
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        tracker.notePractised(excerptId: "ex-b", instrument: .cello)
        clock = clock.addingTimeInterval(86_400)
        let stillOwed: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(stillOwed, .deletePending)
        XCTAssertEqual(api.deleteCalls, 2)
        XCTAssertEqual(api.shared.count, 1)

        api.deleteFails = false
        let done: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(done, .deletedSharedData)
        XCTAssertFalse(uploader.hasPendingDelete)
        let resumed: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(resumed, .sent(1))
        XCTAssertEqual(api.shared.last?.excerptIds, ["ex-b"])
    }

    // MARK: Server answer

    func testResponseDecoding() throws {
        let json: String = """
        {"enough": true, "fromWeek": "2026-W34", "toWeek": "2026-W41",
         "trends": [{"excerptId": "ex-a", "tier": "very-popular"}, {"excerptId": "ex-b", "tier": "popular"}]}
        """
        let decoded: TrendsResponse = try JSONDecoder().decode(TrendsResponse.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enough)
        XCTAssertEqual(decoded.fromWeek, "2026-W34")
        XCTAssertEqual(decoded.toWeek, "2026-W41")
        XCTAssertEqual(decoded.trends.map { $0.excerptId }, ["ex-a", "ex-b"])
        XCTAssertEqual(decoded.trends.map { $0.tier }, ["very-popular", "popular"])

        let empty: String = """
        {"enough": false, "fromWeek": "2026-W34", "toWeek": "2026-W41", "trends": []}
        """
        let notEnough: TrendsResponse = try JSONDecoder().decode(TrendsResponse.self, from: Data(empty.utf8))
        XCTAssertFalse(notEnough.enough)
        XCTAssertTrue(notEnough.trends.isEmpty)
    }

    func testTierDisplayMapping() {
        XCTAssertEqual(TrendTier(serverValue: "very-popular"), .veryPopular)
        XCTAssertEqual(TrendTier(serverValue: " VERY-POPULAR "), .veryPopular)
        XCTAssertEqual(TrendTier(serverValue: "popular"), .popular)
        XCTAssertNil(TrendTier(serverValue: "legendary"))
        XCTAssertNil(TrendTier(serverValue: ""))
        XCTAssertEqual(TrendTier.veryPopular.displayName, "Very popular")
        XCTAssertEqual(TrendTier.popular.displayName, "Popular")
        XCTAssertLessThan(TrendTier.veryPopular.order, TrendTier.popular.order)
    }

    func testAnswerIsCleanedAndOrderedByTier() {
        let answer: TrendsAnswer = TrendsLogic.answer(from: response([
            ("ex-p1", "popular"),
            ("ex-v1", "very-popular"),
            (" ex-p1 ", "popular"),
            ("ex-odd", "legendary"),
            ("", "popular"),
            ("ex-v2", "very-popular"),
        ]))
        XCTAssertTrue(answer.enough)
        XCTAssertEqual(answer.ordered, ["ex-v1", "ex-v2", "ex-p1"], "very popular first, server order within a tier")
        XCTAssertEqual(answer.tier(for: "ex-p1"), .popular)
        XCTAssertEqual(answer.tier(for: "ex-v2"), .veryPopular)
        XCTAssertNil(answer.tier(for: "ex-odd"))
        XCTAssertEqual(answer.tiers.count, 3)

        let few: TrendsAnswer = TrendsLogic.answer(from: response(enough: false, [("ex-v1", "very-popular")]))
        XCTAssertFalse(few.enough)
        XCTAssertTrue(few.ordered.isEmpty, "below 20 contributors nothing is kept, whatever the server sent")
        XCTAssertNil(few.tier(for: "ex-v1"))
    }

    func testEntriesKeepOnlyExcerptsOnThisDevice() {
        let answer: TrendsAnswer = TrendsLogic.answer(from: response([("ex-a", "very-popular"), ("ex-missing", "popular"), ("ex-b", "popular")]))
        let pool: [Excerpt] = [excerpt("ex-b"), excerpt("ex-a"), excerpt("ex-a")]
        let entries: [PopularEntry] = TrendsLogic.entries(answer, in: pool)
        XCTAssertEqual(entries.map { $0.id }, ["ex-a", "ex-b"])
        XCTAssertEqual(entries.map { $0.tier }, [.veryPopular, .popular])
        XCTAssertTrue(TrendsLogic.entries(nil, in: pool).isEmpty)
        XCTAssertTrue(TrendsLogic.entries(answer, in: []).isEmpty)
    }

    func testWordsAndNotes() {
        XCTAssertEqual(TrendsCopy.sectionTitle(for: .cello), "Popular with cello players")
        XCTAssertEqual(TrendsCopy.sectionTitle(for: .doubleBass), "Popular with double bass players")
        XCTAssertEqual(TrendsCopy.badgeText(for: .horn), "Among horn players who share what they practise")
        XCTAssertEqual(TrendsCopy.sectionFooter, "From players who share what they practise — not what orchestras ask.")
        XCTAssertEqual(TrendsCopy.notEnough, "Not enough players share yet to show this.")
        XCTAssertEqual(TrendsLogic.note(for: APIError.server(status: 503, message: "Sharing what you practise isn't set up on the server yet.")),
                       "Sharing what you practise isn't set up on the server yet.")
        XCTAssertEqual(TrendsLogic.note(for: APIError.server(status: 502, message: "Practice trends didn't answer.")),
                       "Couldn't check what other players practise. Try again later.")
        XCTAssertEqual(TrendsLogic.note(for: APIError.notConfigured),
                       "Needs the Auditioner server. Add its address in Settings → Server.")
        XCTAssertEqual(TrendsLogic.note(for: URLError(.notConnectedToInternet)),
                       "Couldn't reach our server to check what other players practise.")
    }

    // MARK: Who sees it

    func testPopularityNeedsSharingAndTheAgeConfirmation() {
        XCTAssertFalse(TrendsSettings.showsPopularity(sharing: false, adultConfirmed: false))
        XCTAssertFalse(TrendsSettings.showsPopularity(sharing: true, adultConfirmed: false))
        XCTAssertFalse(TrendsSettings.showsPopularity(sharing: false, adultConfirmed: true))
        XCTAssertTrue(TrendsSettings.showsPopularity(sharing: true, adultConfirmed: true))
        XCTAssertFalse(TrendsSettings.isSharingOn(defaults), "off by default")
        XCTAssertFalse(TrendsSettings.showsPopularity(defaults))
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        defaults.set(true, forKey: TrendsSettings.adultConfirmedKey)
        XCTAssertTrue(TrendsSettings.showsPopularity(defaults))
    }

    // MARK: Service

    @MainActor
    func testServiceKeepsAnAnswerForAnHour() async {
        var clock: Date = utcDate(2026, 10, 7)
        let service = TrendsService(now: { clock })
        let api = FakeTrendsAPI()
        api.answer = response([("ex-a", "very-popular")])

        await service.refresh(instrument: .cello, client: api)
        XCTAssertEqual(api.trendsCalls, 1)
        XCTAssertEqual(service.tier(for: "ex-a", instrument: .cello), .veryPopular)
        XCTAssertNil(service.tier(for: "ex-a", instrument: .viola), "answers are per instrument")
        XCTAssertNil(service.note(for: .cello))
        XCTAssertFalse(service.isLoading(.cello))

        clock = clock.addingTimeInterval(1800)
        await service.refresh(instrument: .cello, client: api)
        XCTAssertEqual(api.trendsCalls, 1, "half an hour later the answer is reused")

        clock = clock.addingTimeInterval(1801)
        await service.refresh(instrument: .cello, client: api)
        XCTAssertEqual(api.trendsCalls, 2, "after an hour the server is asked again")

        api.trendsError = APIError.server(status: 503, message: "Sharing what you practise isn't set up on the server yet.")
        await service.refresh(instrument: .cello, client: api, force: true)
        XCTAssertEqual(api.trendsCalls, 3)
        XCTAssertEqual(service.note(for: .cello), "Sharing what you practise isn't set up on the server yet.")
        XCTAssertEqual(service.tier(for: "ex-a", instrument: .cello), .veryPopular, "the old answer stays when the server fails")

        service.forget()
        XCTAssertNil(service.answer(for: .cello))
        XCTAssertFalse(service.isFresh(.cello))
    }
}
