import Foundation
import Combine

/// Loads the open-auditions feed for the player's instrument and region (PLAN F1).
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

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?

    /// Loads once per settings change; `refreshable` passes `force: true`.
    func refresh(settings: AppSettings, force: Bool = false, now: Date = Date(), calendar: Calendar = .current) async {
        guard settings.serverBaseURL != nil else {
            task?.cancel()
            task = nil
            state = .notConfigured
            return
        }
        if !force {
            if case .loaded = state { return }
            if case .loading = state { return }
        }
        task?.cancel()
        let client: APIClient = APIClient.fromSettings(settings)
        let instrument: Instrument = settings.instrument
        let region: String = settings.region
        state = .loading
        let work: Task<Void, Never> = Task { [weak self] in
            do {
                let list: [FeedVacancy] = try await client.auditions(instrument: instrument, region: region)
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
