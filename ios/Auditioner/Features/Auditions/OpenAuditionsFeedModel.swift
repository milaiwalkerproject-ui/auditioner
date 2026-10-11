import Foundation
import Combine

/// Loads the open-auditions feed for the player's instrument and region, or every region (PLAN F1, F5).
/// Only published vacancies come back from the server; the app never invents a row.
@MainActor
final class OpenAuditionsFeedModel: ObservableObject {
    enum State: Equatable {
        case idle
        /// No server address in Settings → Server.
        case notConfigured
        case loading
        case loaded([FeedVacancy])
        case failed(String)
    }

    /// What one load asked the server for; a different request means the feed must load again.
    struct Request: Equatable {
        let instrument: Instrument
        /// `nil` = every region.
        let region: String?
        let server: String

        init(settings: AppSettings, allRegions: Bool) {
            self.instrument = settings.instrument
            self.region = OpenAuditionsLogic.feedRegion(allRegions: allRegions, region: settings.region)
            self.server = settings.serverURL
        }
    }

    @Published private(set) var state: State = .idle
    /// "All regions" (true) or the player's region (false); remembered in UserDefaults.
    @Published private(set) var allRegions: Bool

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// The request behind `state` (loading or loaded), so a repeat call with the same settings does nothing.
    private var currentRequest: Request?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.allRegions = OpenAuditionsLogic.showsAllRegions(defaults)
    }

    /// Remembers the choice; the caller then calls `refresh(settings:)` so the feed follows it.
    func setAllRegions(_ on: Bool) {
        guard on != allRegions else { return }
        allRegions = on
        OpenAuditionsLogic.setShowsAllRegions(on, defaults)
    }

    /// Loads when the instrument, region, scope or server changed since the last load; `refreshable`
    /// passes `force: true` to load again regardless.
    func refresh(settings: AppSettings, force: Bool = false, now: Date = Date(), calendar: Calendar = .current) async {
        guard settings.serverBaseURL != nil else {
            task?.cancel()
            task = nil
            currentRequest = nil
            state = .notConfigured
            return
        }
        let request = Request(settings: settings, allRegions: allRegions)
        if !force, request == currentRequest {
            if case .loaded = state { return }
            if case .loading = state { return }
        }
        task?.cancel()
        let client: APIClient = APIClient.fromSettings(settings)
        currentRequest = request
        state = .loading
        let work: Task<Void, Never> = Task { [weak self] in
            do {
                let list: [FeedVacancy] = try await client.auditions(instrument: request.instrument, region: request.region)
                if Task.isCancelled { return }
                self?.state = .loaded(OpenAuditionsLogic.openSorted(list, today: now, calendar: calendar))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
        task = work
        await work.value
    }

    var vacancies: [FeedVacancy] {
        if case .loaded(let list) = state { return list }
        return []
    }
}
