import SwiftUI
import SwiftData

@main
struct AuditionerApp: App {
    @StateObject private var catalog = CatalogStore()
    @StateObject private var router = AppRouter()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                // Resends queued "Report an error" / "Send feedback" messages on launch and when the app comes back.
                .flushesFeedbackQueue()
                // Signed in with Apple? Ask Apple once per launch whether that still stands (PLAN B2).
                .task { await AccountStore.shared.refreshCredentialState() }
                // Opt-in "Popular with other players" (PLAN D6): uploads this week's practised excerpts, at most once per 12 h.
                .syncsPracticeTrends()
                .environmentObject(catalog)
                .environmentObject(router)
                .environmentObject(settings)
                .tint(Theme.garnet)
        }
        .modelContainer(for: PersistenceSchema.models)
    }
}
