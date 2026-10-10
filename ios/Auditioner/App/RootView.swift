import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ExcerptBrowserView()
                .tabItem { Label("Excerpts", systemImage: "music.note.list") }
                .tag(AppTab.excerpts)
            LibraryView()
                .tabItem { Label("My parts", systemImage: "doc.richtext") }
                .tag(AppTab.library)
            PracticeHomeView()
                .tabItem { Label("Practice", systemImage: "metronome") }
                .tag(AppTab.practice)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .fullScreenCover(item: $router.scanContext) { context in
            ScanFlowView(context: context)
                .environmentObject(router)
        }
        .fullScreenCover(item: $router.practiceDocument) { document in
            PracticePlayerView(document: document)
                .environmentObject(router)
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { newValue in if !newValue { settings.hasCompletedOnboarding = true } }
        )) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .onOpenURL { url in
            importSharedFile(url)
        }
    }

    /// A PDF or image handed over by the Share sheet / "Open in Auditioner" goes straight into My parts.
    private func importSharedFile(_ url: URL) {
        guard url.isFileURL else { return }
        do {
            try LibraryStore.importFile(at: url, context: modelContext)
            router.selectedTab = .library
        } catch {
            NSLog("Auditioner: couldn't import shared file: %@", error.localizedDescription)
        }
    }
}
