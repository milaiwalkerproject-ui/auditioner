import SwiftUI
import SwiftData

/// Where the Auditions tab can go.
enum AuditionsRoute: Hashable {
    case audition(UUID)
    case vacancy(FeedVacancy)
}

/// The Auditions tab: "My auditions" (readiness, countdown) and the open-auditions feed for
/// the player's instrument (PLAN F1–F4).
struct AuditionsHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Audition.createdAt, order: .reverse) private var auditions: [Audition]
    @Query private var allItems: [AuditionItem]

    @StateObject private var feed = OpenAuditionsFeedModel()
    @State private var path = NavigationPath()
    @State private var isCreating: Bool = false
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
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                AuditionFormView(mode: .create) { created in
                    path.append(AuditionsRoute.audition(created.id))
                }
            }
        }
        .sheet(item: $safariItem) { item in
            ExcerptSafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    /// Reload the feed when the instrument, region or server changes.
    private var feedKey: String {
        settings.instrumentRaw + "|" + settings.region + "|" + settings.serverURL
    }

    // MARK: My auditions

    private var sortedAuditions: [Audition] {
        auditions.sorted { a, b in
            let da: Date = AuditionOrdering.sortDate(auditionDate: a.auditionDate, deadline: a.applicationDeadline)
            let db: Date = AuditionOrdering.sortDate(auditionDate: b.auditionDate, deadline: b.applicationDeadline)
            if da != db { return da < db }
            return a.createdAt > b.createdAt
        }
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
        } header: {
            Text("My auditions")
        }
    }

    // MARK: Open auditions

    private var openAuditionsSection: some View {
        Section {
            feedContent
        } header: {
            Text("Open auditions · \(settings.instrument.displayName)")
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
        }
    }
}
