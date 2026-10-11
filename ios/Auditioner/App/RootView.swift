import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.modelContext) private var modelContext

    /// The player is presented from this copy of `router.practiceDocument` so it can wait until the scan
    /// cover has finished closing: `AppRouter.openPractice` clears the scan context and sets the document in
    /// one go, and SwiftUI can drop a cover that is presented while another one is still animating away.
    @State private var presentedPractice: ScoreDocument? = nil
    @State private var isScanCoverShowing: Bool = false
    /// An `auditioner://excerpt/…` link named an excerpt this device's catalogue doesn't have (PLAN U1).
    @State private var isShowingMissingExcerptNote: Bool = false

    var body: some View {
        tabs
            .fullScreenCover(item: $router.scanContext, onDismiss: scanCoverDidClose) { context in
                ScanFlowView(context: context)
                    .environmentObject(router)
                    .onAppear { isScanCoverShowing = true }
            }
            .fullScreenCover(item: $presentedPractice, onDismiss: practiceCoverDidClose) { document in
                PracticePlayerView(document: document)
                    .environmentObject(router)
            }
            .sheet(isPresented: onboardingBinding) {
                OnboardingView()
                    .interactiveDismissDisabled()
            }
            .onChange(of: router.practiceDocument) { _, newValue in
                practiceDocumentChanged(newValue)
            }
            .onOpenURL { url in
                if url.isFileURL {
                    importSharedFile(url)
                } else {
                    openDeepLink(url)
                }
            }
            .alert("That excerpt isn't in the catalogue on this device yet.", isPresented: $isShowingMissingExcerptNote) {
                Button("OK", role: .cancel) { }
            }
    }

    private var tabs: some View {
        TabView(selection: $router.selectedTab) {
            ExcerptBrowserView()
                .tabItem { Label("Excerpts", systemImage: "music.note.list") }
                .tag(AppTab.excerpts)
            AuditionsHomeView()
                .tabItem { Label("Auditions", systemImage: "calendar") }
                .tag(AppTab.auditions)
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
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { newValue in
                if !newValue {
                    settings.hasCompletedOnboarding = true
                }
            }
        )
    }

    // MARK: Presentation sequencing

    private func practiceDocumentChanged(_ newValue: ScoreDocument?) {
        guard let document = newValue else {
            presentedPractice = nil
            return
        }
        if isScanCoverShowing {
            // The scan cover is still on screen (closing); `scanCoverDidClose` presents the player.
            return
        }
        presentedPractice = document
    }

    private func scanCoverDidClose() {
        isScanCoverShowing = false
        if let pending = router.practiceDocument, presentedPractice == nil {
            presentedPractice = pending
        }
    }

    private func practiceCoverDidClose() {
        if router.practiceDocument != nil {
            router.practiceDocument = nil
        }
    }

    /// An `auditioner://` link from Tutti or elsewhere (PLAN U1, docs/TUTTI.md): open an excerpt page, or the
    /// Auditions tab with the "New audition" form filled in. Anything else is ignored.
    private func openDeepLink(_ url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        let outcome: DeepLinkRouting.Outcome = DeepLinkRouting.follow(link, router: router, catalog: catalog)
        if outcome == .excerptMissing {
            isShowingMissingExcerptNote = true
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
