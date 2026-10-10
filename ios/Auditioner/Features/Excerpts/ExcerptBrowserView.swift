import SwiftUI

/// Catalogue browser for the selected instrument: search, position and frequency filters,
/// rows grouped by composer. Pushes `ExcerptDetailView` by excerpt id, also when another
/// feature sets `AppRouter.openedExcerptId` (e.g. after a scan was identified).
struct ExcerptBrowserView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var router: AppRouter

    @AppStorage(SettingsKey.instrument) private var instrumentRaw: String = Instrument.cello.rawValue
    @AppStorage(SettingsKey.position) private var positionRaw: String = Position.section.rawValue
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @State private var path = NavigationPath()
    @State private var query: String = ""
    @State private var positionFilter: ExcerptPositionFilter = .all
    @State private var tierFilter: ExcerptTierFilter = .all
    @State private var didSeedFilters: Bool = false

    private var instrument: Instrument {
        Instrument(rawValue: instrumentRaw) ?? .cello
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Excerpts")
                .searchable(text: $query, prompt: Text("Composer, work or excerpt"))
                .toolbar { toolbarContent }
                .navigationDestination(for: String.self) { excerptId in
                    destination(for: excerptId)
                }
        }
        .onAppear {
            seedFiltersIfNeeded()
            consumeOpenedExcerpt()
        }
        .onChange(of: router.openedExcerptId) { _, _ in
            consumeOpenedExcerpt()
        }
    }

    // MARK: Data

    /// Everything the catalogue has for this instrument (drafts included in reviewer mode).
    private var allForInstrument: [Excerpt] {
        catalog.excerpts(for: instrument, includeDrafts: reviewerMode)
    }

    private var sections: [ExcerptSection] {
        let found = catalog.search(query, instrument: instrument, includeDrafts: reviewerMode)
        let filtered = ExcerptBrowserLogic.filter(found, position: positionFilter, tier: tierFilter)
        return ExcerptBrowserLogic.group(filtered)
    }

    private var isFiltering: Bool {
        positionFilter != .all || tierFilter != .all
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if allForInstrument.isEmpty {
            preparingState
        } else if sections.isEmpty {
            noMatchesState
        } else {
            excerptList
        }
    }

    private var excerptList: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.excerpts) { excerpt in
                        NavigationLink(value: excerpt.id) {
                            ExcerptRow(excerpt: excerpt, reviewerMode: reviewerMode)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var preparingState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "music.note.list")
        } description: {
            Text("The \(instrument.displayName.lowercased()) catalogue is still being prepared. Check back after the next update.")
        } actions: {
            if ScoreDocument.demoScale() != nil {
                Button("Try the demo") {
                    if let demo = ScoreDocument.demoScale() {
                        router.openPractice(demo)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label("No excerpts match", systemImage: "magnifyingglass")
        } description: {
            Text("Try another spelling, or clear the filters.")
        } actions: {
            if isFiltering {
                Button("Clear filters") {
                    positionFilter = .all
                    tierFilter = .all
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for excerptId: String) -> some View {
        if let excerpt = catalog.excerpt(id: excerptId) {
            ExcerptDetailView(excerpt: excerpt)
        } else {
            ContentUnavailableView("Not in the catalogue", systemImage: "questionmark.circle",
                                   description: Text("This excerpt isn't in the catalogue on this device yet."))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            instrumentMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
            filterMenu
        }
    }

    private var instrumentMenu: some View {
        let ordered = ExcerptBrowserLogic.orderedInstruments(withContent: catalog.instrumentsWithContent)
        return Menu {
            Picker("Instrument", selection: $instrumentRaw) {
                ForEach(ordered.first) { item in
                    Text(item.displayName).tag(item.rawValue)
                }
            }
            if !ordered.more.isEmpty {
                Menu("More instruments") {
                    Picker("More instruments", selection: $instrumentRaw) {
                        ForEach(ordered.more) { item in
                            Text(item.displayName).tag(item.rawValue)
                        }
                    }
                }
            }
        } label: {
            Label(instrument.displayName, systemImage: "music.note")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Position", selection: $positionFilter) {
                Text("All positions").tag(ExcerptPositionFilter.all)
                ForEach(ExcerptBrowserLogic.filterablePositions) { position in
                    Text(position.displayName).tag(ExcerptPositionFilter.position(position))
                }
            }
            Picker("How often it's asked", selection: $tierFilter) {
                Text("Any frequency").tag(ExcerptTierFilter.all)
                Text(FrequencyTier.core.displayName).tag(ExcerptTierFilter.tier(.core))
                Text(FrequencyTier.common.displayName).tag(ExcerptTierFilter.tier(.common))
                Text(FrequencyTier.occasional.displayName).tag(ExcerptTierFilter.tier(.occasional))
            }
        } label: {
            Label("Filter", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: Routing

    private func seedFiltersIfNeeded() {
        guard !didSeedFilters else { return }
        didSeedFilters = true
        if let position = Position(rawValue: positionRaw), position != .any {
            positionFilter = .position(position)
        } else {
            positionFilter = .all
        }
    }

    /// Pushes the excerpt another feature asked for, then clears the request.
    private func consumeOpenedExcerpt() {
        guard let excerptId = router.openedExcerptId else { return }
        router.openedExcerptId = nil
        if router.selectedTab != .excerpts {
            router.selectedTab = .excerpts
        }
        path.append(excerptId)
    }
}

/// One row of the browser: composer · work, subtitle, and the pills the honesty contract allows.
struct ExcerptRow: View {
    let excerpt: Excerpt
    let reviewerMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(excerpt.workHeading)
                .font(Theme.displayFont(.headline))
                .foregroundStyle(Theme.ink)
            Text(excerpt.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            pills
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var pills: some View {
        if hasPills {
            HStack(spacing: 6) {
                if let tier = excerpt.frequency?.verifiedTier {
                    TagPill(text: tier.displayName, color: Theme.brass)
                }
                if let difficulty = excerpt.difficulty, difficulty.reviewStatus == .approved {
                    TagPill(text: ExcerptFormat.difficultyLabel(difficulty.value), color: Theme.slate)
                }
                if excerpt.provenanceType == "imported" {
                    TagPill(text: String(localized: "Imported"), color: Theme.teal)
                }
                if reviewerMode && excerpt.listingStatus != .published {
                    TagPill(text: String(localized: "Draft"), color: Theme.garnet)
                }
            }
            .padding(.top, 2)
        }
    }

    private var hasPills: Bool {
        if excerpt.frequency?.verifiedTier != nil { return true }
        if let difficulty = excerpt.difficulty, difficulty.reviewStatus == .approved { return true }
        if excerpt.provenanceType == "imported" { return true }
        if reviewerMode && excerpt.listingStatus != .published { return true }
        return false
    }
}
