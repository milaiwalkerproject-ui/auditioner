import XCTest
@testable import Auditioner

/// `TrendsUploader` sends one request at a time (PLAN D6): turning sharing off while a POST is in
/// flight must not let the DELETE overtake it (the server would delete first and the POST would
/// re-create the row), and no POST starts once sharing is off. Synthetic ids; the clock, UserDefaults
/// and the network are injected. The fake client can hold a request open until the test releases it.
final class TrendsUploaderOrderingTests: XCTestCase {

    private var suiteName: String = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TrendsUploaderOrderingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            XCTFail("bad test date \(year)-\(month)-\(day)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    /// Records every request in the order it started and ended, and can hold POSTs or DELETEs open.
    private final class HoldingTrendsAPI: TrendsAPI {
        var isConfigured: Bool = true
        var holdsPosts: Bool = false
        var holdsDeletes: Bool = false

        private let lock = NSLock()
        private var log: [String] = []
        private var heldPosts: [CheckedContinuation<Void, Never>] = []
        private var heldDeletes: [CheckedContinuation<Void, Never>] = []

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }

        var postsStarted: Int { events.filter { $0.hasPrefix("post-start") }.count }
        var postsEnded: Int { events.filter { $0.hasPrefix("post-end") }.count }
        var deletesStarted: Int { events.filter { $0 == "delete-start" }.count }
        var deletesEnded: Int { events.filter { $0 == "delete-end" }.count }

        private func record(_ event: String) {
            lock.lock()
            log.append(event)
            lock.unlock()
        }

        /// Lets every POST the fake server is holding finish.
        func releasePosts() {
            lock.lock()
            let held: [CheckedContinuation<Void, Never>] = heldPosts
            heldPosts = []
            lock.unlock()
            for continuation in held {
                continuation.resume()
            }
        }

        /// Lets every DELETE the fake server is holding finish.
        func releaseDeletes() {
            lock.lock()
            let held: [CheckedContinuation<Void, Never>] = heldDeletes
            heldDeletes = []
            lock.unlock()
            for continuation in held {
                continuation.resume()
            }
        }

        func shareTrends(instrument: Instrument, week: String, excerptIds: [String]) async throws {
            record("post-start \(week)")
            if holdsPosts {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    heldPosts.append(continuation)
                    lock.unlock()
                }
            }
            record("post-end \(week)")
        }

        func forgetTrends() async throws {
            record("delete-start")
            if holdsDeletes {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    heldDeletes.append(continuation)
                    lock.unlock()
                }
            }
            record("delete-end")
        }

        func trends(instrument: Instrument) async throws -> TrendsResponse {
            TrendsResponse(enough: false, fromWeek: "2026-W34", toWeek: "2026-W41", trends: [])
        }
    }

    /// Polls until `condition` holds (a few seconds at most), letting the other tasks run meanwhile.
    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    /// Gives every queued task a chance to run (to check that something did *not* happen).
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Tests

    @MainActor
    func testDeleteWaitsForThePostInFlightAndNoFurtherPostStarts() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7) // 2026-W41
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = HoldingTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        clock = utcDate(2026, 10, 13) // 2026-W42: two sets to send, last week's first
        tracker.notePractised(excerptId: "ex-b", instrument: .cello)

        api.holdsPosts = true
        let syncing: Task<TrendsSyncOutcome, Never> = Task { @MainActor in
            await uploader.sync()
        }
        await waitUntil({ api.postsStarted == 1 }, "the first POST should be in flight")

        // The player turns sharing off while that POST is still out.
        defaults.set(false, forKey: TrendsSettings.sharingKey)
        let turningOff: Task<Void, Never> = Task { @MainActor in
            await uploader.sharingTurnedOff()
        }
        await settle()
        XCTAssertTrue(tracker.sets().isEmpty, "the local sets go at once")
        XCTAssertTrue(uploader.hasPendingDelete, "the DELETE is owed from the moment sharing goes off")
        XCTAssertEqual(api.deletesStarted, 0, "the DELETE waits for the POST in flight")
        XCTAssertEqual(api.postsStarted, 1, "no second POST starts once sharing is off")

        api.releasePosts()
        let outcome: TrendsSyncOutcome = await syncing.value
        await turningOff.value
        XCTAssertEqual(api.events, ["post-start 2026-W41", "post-end 2026-W41", "delete-start", "delete-end"],
                       "the DELETE goes out after the POST has finished, and the second set is never posted")
        XCTAssertEqual(outcome, .sent(1))
        XCTAssertFalse(uploader.hasPendingDelete, "a DELETE sent after the last POST clears the owed flag")
        XCTAssertNil(uploader.lastUploadAt)
    }

    @MainActor
    func testSyncWaitsForADeleteInFlightAndPostsOnlyAfterIt() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        var clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = HoldingTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)
        let first: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(first, .sent(1))

        // Off: the DELETE is held open by the fake server.
        defaults.set(false, forKey: TrendsSettings.sharingKey)
        api.holdsDeletes = true
        let turningOff: Task<Void, Never> = Task { @MainActor in
            await uploader.sharingTurnedOff()
        }
        await waitUntil({ api.deletesStarted == 1 }, "the DELETE should be in flight")

        // On again straight away, something practised, and the app comes to the front.
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        tracker.notePractised(excerptId: "ex-c", instrument: .cello)
        clock = clock.addingTimeInterval(13 * 3600)
        let syncing: Task<TrendsSyncOutcome, Never> = Task { @MainActor in
            await uploader.sync()
        }
        await settle()
        XCTAssertEqual(api.postsStarted, 1, "no POST while the DELETE is in flight")
        XCTAssertEqual(api.deletesStarted, 1, "the sync doesn't send a second DELETE alongside")

        api.releaseDeletes()
        await turningOff.value
        let outcome: TrendsSyncOutcome = await syncing.value
        XCTAssertEqual(outcome, .sent(1), "once the DELETE is through the sync uploads the new set")
        XCTAssertEqual(api.events, ["post-start 2026-W41", "post-end 2026-W41",
                                    "delete-start", "delete-end",
                                    "post-start 2026-W41", "post-end 2026-W41"])
        XCTAssertFalse(uploader.hasPendingDelete)
    }

    @MainActor
    func testTwoQuickOffSwitchesSendTheirDeletesOneAfterTheOther() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        let clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = HoldingTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })

        api.holdsDeletes = true
        defaults.set(false, forKey: TrendsSettings.sharingKey)
        let firstOff: Task<Void, Never> = Task { @MainActor in
            await uploader.sharingTurnedOff()
        }
        await waitUntil({ api.deletesStarted == 1 }, "the first DELETE should be in flight")
        let secondOff: Task<Void, Never> = Task { @MainActor in
            await uploader.sharingTurnedOff()
        }
        await settle()
        XCTAssertEqual(api.deletesStarted, 1, "the second DELETE waits for the first")

        api.releaseDeletes()
        await firstOff.value
        await waitUntil({ api.deletesStarted == 2 }, "the second DELETE should follow")
        api.releaseDeletes()
        await secondOff.value
        XCTAssertEqual(api.events, ["delete-start", "delete-end", "delete-start", "delete-end"])
        XCTAssertFalse(uploader.hasPendingDelete)
    }

    @MainActor
    func testASecondSyncWhileOneIsRunningDoesNothing() async {
        defaults.set(true, forKey: TrendsSettings.sharingKey)
        let clock: Date = utcDate(2026, 10, 7)
        let tracker = TrendsTracker(defaults: defaults, now: { clock })
        let api = HoldingTrendsAPI()
        let uploader = TrendsUploader(defaults: defaults, tracker: tracker, now: { clock }, makeClient: { api })
        tracker.notePractised(excerptId: "ex-a", instrument: .cello)

        api.holdsPosts = true
        let syncing: Task<TrendsSyncOutcome, Never> = Task { @MainActor in
            await uploader.sync()
        }
        await waitUntil({ api.postsStarted == 1 }, "the POST should be in flight")
        let again: TrendsSyncOutcome = await uploader.sync()
        XCTAssertEqual(again, .alreadyRunning)

        api.releasePosts()
        let outcome: TrendsSyncOutcome = await syncing.value
        XCTAssertEqual(outcome, .sent(1))
        XCTAssertEqual(api.postsStarted, 1)
    }
}
