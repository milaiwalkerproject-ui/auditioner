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
                .environmentObject(catalog)
                .environmentObject(router)
                .environmentObject(settings)
                .tint(Theme.garnet)
        }
        .modelContainer(for: PersistenceSchema.models)
    }
}
