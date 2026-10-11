import SwiftUI
import SwiftData

/// Where the Auditions tab can go.
enum AuditionsRoute: Hashable {
    case audition(UUID)
    case vacancy(FeedVacancy)
    /// The archived auditions (PLAN F5): restore, or delete for good.
    case archived
}

/// The Auditions tab: "My auditions" (readiness, countdown), the archive row, and the open-auditions
/// feed for the player's instrument in their region or every region (PLAN F1–F5).
struct AuditionsHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Audition.createdAt, order: .reverse) private var auditions: [Audition]
    @Query private var allItems: [AuditionItem]

    @StateObject private var feed = OpenAuditionsFeedModel()
    @State private var path = NavigationPath()
    @State private var isCreating: Bool = false
    /// What the "New audition" form starts with: empty from the + button, filled in from a link (PLAN U1).
    @State private var createPrefill: AuditionPrefill = AuditionPrefill()
    /// Changes every time the form is presented, so the form in the sheet starts again from
    /// `createPrefill` (its fields are read once, when the form is made).
    @State private var createFormId: UUID = UUID()
    @State private var safariItem: SafariLinkItem? = nil

    var body: some View {
        NavigationStack(path: $path) {
            List {
                myAuditionsSection
                openAuditionsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Auditions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createPrefill = AuditionPrefill()
                        createFormId = UUID()
                        isCreating = true
                    } label: {
                        Label("New audition", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: AuditionsRoute.self) { route in
                destination(route)
            }
            .refreshable {
                await feed.refresh(settings: settings, force: true)
            }
        }
        .task(id: feedKey) {
            await feed.refresh(settings: settings)
        }
        .onAppear {
            consumeLinkPrefill()
        }
        .onChange(of: router.auditionPrefill) { _, _ in
            consumeLinkPrefill()
        }
        .sheet(isPresented: $isCreating, onDismiss: consumeLinkPrefill) {
            NavigationStack {
                AuditionFormView(mode: .create, prefill: createPrefill) { created in
                    path.append(AuditionsRoute.audition(created.id))
                }
            }
            .id(createFormId)
            .onAppear(perform: formDidShowPrefill)
        }
        .sheet(item: $safariItem, onDismiss: consumeLinkPrefill) { item in
            ExcerptSafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    /// Reload the feed when the instrument, region or server changes.
    private var feedKey: String {
        settings.instrumentRaw + "|" + settings.region + "|" + settings.serverURL
    }

    /// Opens the "New audition" form filled in from an `auditioner://audition/new` link (PLAN U1). The
    /// request stays in the router until a form has actually shown it (`formDidShowPrefill`), so it is
    /// not lost when a sheet is already up: that sheet is closed first, and its `onDismiss` comes back
    /// here to present a fresh form. Nothing is saved until the player taps Add.
    private func consumeLinkPrefill() {
        switch AuditionLinkPresentation.step(pending: router.auditionPrefill,
                                             sheetIsUp: isCreating || safariItem != nil) {
        case .nothing:
            return
        case .dismissSheetFirst:
            isCreating = false
            safariItem = nil
        case .present(let prefill):
            createPrefill = prefill
            createFormId = UUID()
            isCreating = true
        }
    }

    /// The form in the sheet is on screen: the link's request has been shown and can be cleared.
    private func formDidShowPrefill() {
        if AuditionLinkPresentation.clearsPending(router.auditionPrefill, shownPrefill: createPrefill) {
            router.auditionPrefill = nil
        }
    }

    // MARK: My auditions

    /// Archived auditions stay out of this list; they live behind the "Archived (N)" row.
    private var sortedAuditions: [Audition] {
        auditions.filter { !$0.isArchived }.sorted { a, b in
            let da: Date = AuditionOrdering.sortDate(auditionDate: a.auditionDate, deadline: a.applicationDeadline)
            let db: Date = AuditionOrdering.sortDate(auditionDate: b.auditionDate, deadline: b.applicationDeadline)
            if da != db { return da < db }
            return a.createdAt > b.createdAt
        }
    }

    private var archivedCount: Int {
        auditions.filter { $0.isArchived }.count
    }

    private func ratings(for audition: Audition) -> [Int?] {
        allItems.filter { $0.auditionId == audition.id }.map { $0.readiness }
    }

    private var myAuditionsSection: some View {
        Section {
            if sortedAuditions.isEmpty {
                AuditionsNoteRow(symbol: "calendar.badge.plus",
                                 title: String(localized: "No audition yet"),
                                 detail: String(localized: "Pick one from the open auditions below, or tap + to add your own with its list."))
            }
            ForEach(sortedAuditions) { audition in
                NavigationLink(value: AuditionsRoute.audition(audition.id)) {
                    AuditionSummaryRow(audition: audition, ratings: ratings(for: audition))
                }
            }
            if AuditionArchive.showsArchivedRow(count: archivedCount) {
                NavigationLink(value: AuditionsRoute.archived) {
                    Label(AuditionArchive.archivedRowTitle(count: archivedCount), systemImage: "archivebox")
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        } header: {
            Text("My auditions")
        }
    }

    // MARK: Open auditions

    private var regionName: String {
        ProfileOptions.regionName(id: settings.region)
    }

    /// The picker writes through the model so the choice is remembered, then the feed reloads for it.
    private var allRegionsBinding: Binding<Bool> {
        Binding(
            get: { feed.allRegions },
            set: { newValue in
                feed.setAllRegions(newValue)
                Task { await feed.refresh(settings: settings) }
            }
        )
    }

    private var openAuditionsSection: some View {
        Section {
            if feed.state != .notConfigured {
                Picker(selection: allRegionsBinding) {
                    Text(OpenAuditionsLogic.scopeTitle(allRegions: false, regionName: regionName)).tag(false)
                    Text(OpenAuditionsLogic.scopeTitle(allRegions: true, regionName: regionName)).tag(true)
                } label: {
                    Label("Show", systemImage: "globe")
                }
                .pickerStyle(.menu)
            }
            feedContent
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open auditions · \(settings.instrument.displayName)")
                Text(OpenAuditionsLogic.scopeTitle(allRegions: feed.allRegions, regionName: regionName))
                    .textCase(nil)
            }
        } footer: {
            if case .loaded(let list) = feed.state, !list.isEmpty {
                Text("Facts come from each orchestra's own website and were checked by a person. Always confirm on the official page before applying.")
            }
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        switch feed.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Looking for open auditions…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.vertical, 4)
        case .notConfigured:
            AuditionsNoteRow(symbol: "antenna.radiowaves.left.and.right.slash",
                             title: String(localized: "The feed isn't connected yet"),
                             detail: String(localized: "Open auditions arrive from the Auditioner server. Add its address in Settings → Server. You can still add your own audition with +."))
        case .failed(let message):
            AuditionsNoteRow(symbol: "exclamationmark.triangle",
                             title: String(localized: "Couldn't load the feed"),
                             detail: message)
            Button {
                Task { await feed.refresh(settings: settings, force: true) }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
        case .loaded(let list):
            if list.isEmpty {
                AuditionsNoteRow(symbol: "tray",
                                 title: String(localized: "No open \(settings.instrument.displayName.lowercased()) auditions right now"),
                                 detail: String(localized: "We list only auditions published on orchestras' own websites and checked by a person. Pull down to look again."))
            }
            ForEach(list) { vacancy in
                NavigationLink(value: AuditionsRoute.vacancy(vacancy)) {
                    FeedVacancyRow(vacancy: vacancy)
                }
            }
        }
    }

    // MARK: Routing

    @ViewBuilder
    private func destination(_ route: AuditionsRoute) -> some View {
        switch route {
        case .audition(let id):
            if let audition = auditions.first(where: { $0.id == id }) ?? AuditionsStore.audition(id: id, context: modelContext) {
                AuditionDetailView(audition: audition)
            } else {
                ContentUnavailableView("Audition not found", systemImage: "questionmark.circle",
                                       description: Text("This audition was deleted."))
            }
        case .vacancy(let vacancy):
            FeedVacancyDetailView(vacancy: vacancy,
                                  onPrepared: { audition in
                                      path.append(AuditionsRoute.audition(audition.id))
                                  },
                                  onOpenLink: { url in
                                      safariItem = SafariLinkItem.make(url)
                                  })
        case .archived:
            ArchivedAuditionsView()
        }
    }
}

// MARK: - Link prefill (pure)

/// How the Auditions tab answers an `auditioner://audition/new` request (PLAN U1) given what is on
/// screen. Pure, so it can be unit-tested; `AuditionsHomeView.consumeLinkPrefill` acts on the step.
enum AuditionLinkPresentation {
    enum Step: Equatable {
        /// No request pending.
        case nothing
        /// A sheet is up (a form or the in-app browser): close it; its `onDismiss` asks again.
        case dismissSheetFirst
        /// Present a fresh form with this prefill.
        case present(AuditionPrefill)
    }

    static func step(pending: AuditionPrefill?, sheetIsUp: Bool) -> Step {
        guard let prefill: AuditionPrefill = pending else { return .nothing }
        return sheetIsUp ? .dismissSheetFirst : .present(prefill)
    }

    /// The router's request is cleared only once a form showing exactly it is on screen — not
    /// when a form opened from the + button (or an earlier link) happens to appear.
    static func clearsPending(_ pending: AuditionPrefill?, shownPrefill: AuditionPrefill) -> Bool {
        guard let prefill: AuditionPrefill = pending else { return false }
        return prefill == shownPrefill
    }
}
