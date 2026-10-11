import SwiftUI
import SwiftData

/// One open audition from the feed: the facts, the published list, and "Prepare for this audition".
struct FeedVacancyDetailView: View {
    let vacancy: FeedVacancy
    let onPrepared: (Audition) -> Void
    let onOpenLink: (URL) -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.modelContext) private var modelContext

    @State private var errorMessage: String? = nil

    /// Feed items keep their published order.
    private struct IndexedItem: Identifiable {
        let index: Int
        let item: FeedVacancyItem
        var id: Int { index }
    }

    private var indexedItems: [IndexedItem] {
        var result: [IndexedItem] = []
        for (index, item) in vacancy.items.enumerated() {
            result.append(IndexedItem(index: index, item: item))
        }
        return result
    }

    private var groups: [AuditionItemGroup<IndexedItem>] {
        AuditionItemGrouping.groups(indexedItems,
                                    round: { $0.item.round },
                                    category: { $0.item.category },
                                    order: { $0.index })
    }

    private var showRounds: Bool {
        AuditionItemGrouping.showsRounds(groups)
    }

    private var completeness: ListCompleteness {
        ListCompleteness(raw: vacancy.listCompleteness)
    }

    private var alreadyPrepared: Audition? {
        AuditionsStore.audition(vacancyId: vacancy.id, context: modelContext)
    }

    var body: some View {
        List {
            factsSection
            if vacancy.items.isEmpty {
                noListSection
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { entry in
                        FeedItemRow(item: entry.item, excerpt: entry.item.excerptId.flatMap { catalog.excerpt(id: $0) })
                    }
                } header: {
                    Text(group.title(showRound: showRounds))
                }
            }
            prepareSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(vacancy.orchestra)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't prepare this audition", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var factsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(vacancy.position)
                    .font(Theme.displayFont(.title3))
                    .foregroundStyle(Theme.ink)
                Text(OpenAuditionsLogic.instrument(for: vacancy, fallback: settings.instrument).displayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.vertical, 2)
            deadlineRow
            if let line = OpenAuditionsLogic.auditionDatesLine(vacancy.auditionDates) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            }
            if completeness.badgeText != nil {
                VStack(alignment: .leading, spacing: 6) {
                    CompletenessBadge(completeness: completeness)
                    if let note = completeness.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .padding(.vertical, 2)
            }
            FeedSourceLine(orchestra: vacancy.orchestra,
                           lastCheckedAt: vacancy.lastCheckedAt,
                           sourceURL: vacancy.sourceURL,
                           onOpen: onOpenLink)
        }
    }

    @ViewBuilder
    private var deadlineRow: some View {
        if let deadline = AuditionDates.parseDay(vacancy.applicationDeadline, calendar: Calendar.current) {
            CountdownLine(label: String(localized: "Deadline"), date: deadline)
        } else {
            HStack(spacing: 6) {
                Text("Deadline")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                CheckOfficialListLink(url: URL(string: vacancy.sourceURL))
            }
        }
    }

    private var noListSection: some View {
        Section {
            AuditionsNoteRow(symbol: "doc.text.magnifyingglass",
                             title: String(localized: "No list published here"),
                             detail: completeness.note ?? String(localized: "Check the official page for the repertoire. You can add the list yourself once you have it."))
        } header: {
            Text("Repertoire")
        }
    }

    private var prepareSection: some View {
        Section {
            Button {
                prepare()
            } label: {
                Label(alreadyPrepared == nil ? String(localized: "Prepare for this audition") : String(localized: "Open my audition"),
                      systemImage: alreadyPrepared == nil ? "calendar.badge.plus" : "calendar")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("Makes a private checklist on this device with the list above: readiness, tempo, countdown and reminders. Nothing is sent anywhere.")
        }
    }

    // MARK: Actions

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in if !newValue { errorMessage = nil } }
        )
    }

    private func prepare() {
        do {
            let audition: Audition = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: settings.instrument, context: modelContext)
            onPrepared(audition)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One published line of the orchestra's list: the text as printed, and the catalogue excerpt the review linked it to.
struct FeedItemRow: View {
    let item: FeedVacancyItem
    let excerpt: Excerpt?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.rawText)
                .font(.body)
                .foregroundStyle(Theme.ink)
            if let excerpt = excerpt {
                Label(AuditionBuilder.itemTitle(for: excerpt), systemImage: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(Theme.teal)
            }
        }
        .padding(.vertical, 2)
    }
}
