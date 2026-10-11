import SwiftUI

/// What one sync did (for tests and logs).
enum TrendsSyncOutcome: Equatable {
    case alreadyRunning
    /// A DELETE was owed (sharing turned off while the server couldn't be reached) and went through.
    case deletedSharedData
    /// A DELETE is owed and failed again; nothing is uploaded until it succeeds.
    case deletePending
    case sharingOff
    case noServer
    case throttled
    case nothingToSend
    /// Every POST succeeded (how many).
    case sent(Int)
    case failed(sent: Int, failed: Int)
}

/// Posts the practised sets (PLAN D6): when the app starts or comes back to the front, at most once
/// per 12 hours, this week's set and — once — last week's final set. Turning sharing off deletes
/// what was shared (DELETE /v1/trends, best effort, tried again on the next launch if it failed)
/// and clears the local sets.
///
/// Requests go out one at a time, in the order they were asked for: a DELETE never overtakes a POST
/// that is already in flight (the server would delete first and the POST would re-create the row),
/// and no POST starts once sharing is off.
@MainActor
final class TrendsUploader {
    static let shared = TrendsUploader()

    static let minimumIntervalSeconds: TimeInterval = 12 * 3600
    /// UserDefaults key: Double, seconds since 1970 of the last upload attempt.
    static let lastUploadKey: String = "trends.lastUploadAt"
    /// UserDefaults key: Bool, a DELETE is still owed to the server.
    static let pendingDeleteKey: String = "trends.pendingDelete"

    private let defaults: UserDefaults
    private let tracker: TrendsTracker
    private let calendar: Calendar
    private let now: () -> Date
    private let makeClient: () -> TrendsAPI
    private var isSyncing: Bool = false
    /// The last operation queued. Each new one waits for it, so requests never overlap.
    private var lastOperation: Task<Void, Never>? = nil
    /// How many POSTs have started so far (whatever their outcome). A DELETE clears the owed flag
    /// only when no POST started while it was in flight.
    private var postsStarted: Int = 0

    init(defaults: UserDefaults = .standard,
         tracker: TrendsTracker = TrendsTracker.shared,
         calendar: Calendar = TrendsWeek.utcCalendar,
         now: @escaping () -> Date = { Date() },
         makeClient: @escaping () -> TrendsAPI = { APIClient.fromSettings() as TrendsAPI }) {
        self.defaults = defaults
        self.tracker = tracker
        self.calendar = calendar
        self.now = now
        self.makeClient = makeClient
    }

    var lastUploadAt: Date? {
        let seconds: Double = defaults.double(forKey: TrendsUploader.lastUploadKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    var hasPendingDelete: Bool {
        defaults.bool(forKey: TrendsUploader.pendingDeleteKey)
    }

    /// Called when the app starts and whenever it comes back to the front.
    func appBecameActive() async {
        _ = await sync()
    }

    /// Uploads what is owed, after any request already queued (a DELETE from turning sharing off,
    /// for instance) has finished. A second sync while one is queued or running does nothing.
    @discardableResult
    func sync() async -> TrendsSyncOutcome {
        if isSyncing { return .alreadyRunning }
        isSyncing = true
        defer { isSyncing = false }
        return await serialized { [self] in
            await self.performSync()
        }
    }

    /// Sharing was turned off: forget the local sets and ask the server to delete what was shared.
    /// The DELETE is queued behind any POST in flight — sent at once it could reach the server
    /// first, and the POST would then re-create the row. The owed flag is set straight away, so the
    /// running sync starts no further POST. A failed DELETE stays owed and is tried again on the
    /// next launch / return to the front.
    func sharingTurnedOff() async {
        tracker.clearAll()
        defaults.removeObject(forKey: TrendsUploader.lastUploadKey)
        defaults.set(true, forKey: TrendsUploader.pendingDeleteKey)
        _ = await serialized { [self] in
            await self.attemptDelete()
        }
    }

    // MARK: One request at a time

    /// Runs `operation` once every operation queued before it has finished, and returns its result.
    /// (`T: Sendable` because the result crosses a `Task` boundary; both results here are plain values.)
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous: Task<Void, Never>? = lastOperation
        let task: Task<T, Never> = Task { @MainActor in
            if let previous = previous {
                await previous.value
            }
            return await operation()
        }
        lastOperation = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }

    private func performSync() async -> TrendsSyncOutcome {
        if hasPendingDelete {
            let deleted: Bool = await attemptDelete()
            return deleted ? .deletedSharedData : .deletePending
        }
        guard defaults.bool(forKey: TrendsSettings.sharingKey) else { return .sharingOff }
        let client: TrendsAPI = makeClient()
        guard client.isConfigured else { return .noServer }

        let moment: Date = now()
        if let last = lastUploadAt, moment >= last, moment.timeIntervalSince(last) < TrendsUploader.minimumIntervalSeconds {
            return .throttled
        }

        let currentWeek: String = TrendsWeek.id(for: moment, calendar: calendar)
        let previousWeek: String = TrendsWeek.previousId(for: moment, calendar: calendar)
        tracker.prune(keepingWeeks: [currentWeek, previousWeek])
        let sets: [TrendsWeekSet] = tracker.sets().filter { !$0.excerptIds.isEmpty }
        guard !sets.isEmpty else { return .nothingToSend }

        // Counts as this 12-hour slot's attempt whether or not the server answers.
        defaults.set(moment.timeIntervalSince1970, forKey: TrendsUploader.lastUploadKey)

        var sent: Int = 0
        var failed: Int = 0
        for set in sets {
            // Sharing may have been turned off while an earlier POST was in flight: no further POST
            // starts, and the DELETE queued behind this sync goes out once it returns.
            guard defaults.bool(forKey: TrendsSettings.sharingKey), !hasPendingDelete else { break }
            guard let instrument = Instrument(rawValue: set.instrument) else { continue }
            let ids: [String] = Array(set.excerptIds.sorted().prefix(TrendsTracker.maxExcerptsPerWeek))
            postsStarted += 1
            do {
                try await client.shareTrends(instrument: instrument, week: set.week, excerptIds: ids)
                sent += 1
                if set.week == previousWeek {
                    // Last week is over: that was its final set, sent once.
                    tracker.remove(instrument: set.instrument, week: set.week)
                }
            } catch {
                failed += 1
            }
        }
        return failed == 0 ? .sent(sent) : .failed(sent: sent, failed: failed)
    }

    /// One DELETE. True when it went through and the owed flag was cleared.
    private func attemptDelete() async -> Bool {
        let client: TrendsAPI = makeClient()
        guard client.isConfigured else { return false }
        let postsBefore: Int = postsStarted
        do {
            try await client.forgetTrends()
        } catch {
            return false
        }
        // Requests run one at a time, so no POST can have started meanwhile; checked all the same:
        // a POST overlapping the DELETE may have re-created the row, and then the DELETE stays owed.
        guard postsStarted == postsBefore else { return false }
        defaults.removeObject(forKey: TrendsUploader.pendingDeleteKey)
        return true
    }
}

// MARK: - App hook

/// Syncs the practised sets when the app starts and whenever it comes back to the front, and warms
/// the popularity answer for the player's instrument when they share. Applied once, to the root
/// view in `AuditionerApp`.
struct TrendsSyncTrigger: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                await TrendsSyncTrigger.run()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await TrendsSyncTrigger.run()
                    }
                }
            }
    }

    @MainActor
    static func run() async {
        await TrendsUploader.shared.appBecameActive()
        if TrendsSettings.showsPopularity() {
            await TrendsService.shared.refresh(instrument: AppSettings.shared.instrument, client: APIClient.fromSettings())
        }
    }
}

extension View {
    /// Uploads what the player practised (only when they share) and refreshes "Popular with other players".
    func syncsPracticeTrends() -> some View {
        modifier(TrendsSyncTrigger())
    }
}
