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
                .environmentObject(catalog)
                .environmentObject(router)
                .environmentObject(settings)
                .tint(Theme.garnet)
        }
        .modelContainer(for: PersistenceSchema.models)
    }
}
