import SwiftUI
import Combine

/// The "Include all chairs" switch, remembered per instrument (PLAN F5: brass defaults to on).
/// One shared object so the excerpt browser and every excerpt page show the same state; the
/// value itself lives in UserDefaults (`RecommendationSettings`).
@MainActor
final class IncludeAllChairsStore: ObservableObject {
    static let shared = IncludeAllChairsStore()

    /// Bumped on every change so views that read `includeAllChairs(for:)` refresh.
    @Published private(set) var changeCount: Int = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func includeAllChairs(for instrument: Instrument) -> Bool {
        RecommendationSettings.includeAllChairs(for: instrument, defaults: defaults)
    }

    func setIncludeAllChairs(_ on: Bool, for instrument: Instrument) {
        guard on != includeAllChairs(for: instrument) || defaults.object(forKey: RecommendationSettings.includeAllChairsKey(for: instrument)) == nil else { return }
        RecommendationSettings.setIncludeAllChairs(on, for: instrument, defaults: defaults)
        changeCount += 1
    }

    /// For a `Toggle`: reads and writes this instrument's choice.
    func binding(for instrument: Instrument) -> Binding<Bool> {
        Binding(
            get: { self.includeAllChairs(for: instrument) },
            set: { newValue in self.setIncludeAllChairs(newValue, for: instrument) }
        )
    }
}
