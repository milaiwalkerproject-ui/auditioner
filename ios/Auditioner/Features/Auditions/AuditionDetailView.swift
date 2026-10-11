import SwiftUI
import SwiftData

/// Which sheet the detail screen is showing (one at a time keeps SwiftUI's presentation simple).
enum AuditionDetailSheet: Identifiable {
    case editItem(AuditionItem)
    case editDetails
    case typeLine
    case catalogue
    case importList
    case mock([MockAuditionItem])
    case link(URL)

    var id: String {
        switch self {
        case .editItem(let item): return "item-\(item.id.uuidString)"
        case .editDetails: return "details"
        case .typeLine: return "type"
        case .catalogue: return "catalogue"
        case .importList: return "import"
        case .mock: return "mock"
        case .link(let url): return "link-\(url.absoluteString)"
        }
    }
}

/// "My upcoming audition": countdown, the list as a checklist with readiness, the practice plan, reminders.
struct AuditionDetailView: View {
    let audition: Audition

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: CatalogStore

    @Query private var items: [AuditionItem]

    @State private var sheet: AuditionDetailSheet? = nil
    @State private var pushedExcerpt: Excerpt? = nil
    @State private var confirmDelete: Bool = false
    @State private var reminderNotice: String? = nil

    init(audition: Audition) {
        self.audition = audition
        let auditionId: UUID = audition.id
        var descriptor = FetchDescriptor<AuditionItem>(predicate: #Predicate<AuditionItem> { $0.auditionId == auditionId })
        descriptor.sortBy = [SortDescriptor(\AuditionItem.order)]
        _items = Query(descriptor)
    }

    private var groups: [AuditionItemGroup<AuditionItem>] {
        AuditionItemGrouping.groups(items, round: { $0.round }, category: { $0.category }, order: { $0.order })
    }

    private var showRounds: Bool {
        AuditionItemGrouping.showsRounds(groups)
    }

    private var title: String {
        audition.orchestra.isEmpty ? String(localized: "My upcoming audition") : audition.orchestra
    }

    var body: some View {
        List {
            AuditionHeaderSection(audition: audition,
                                  ratings: items.map { $0.readiness },
                                  remindersOn: remindersBinding,
                                  reminderNotice: reminderNotice,
                                  onOpenLink: { url in sheet = .link(url) },
                                  onEdit: { sheet = .editDetails })
            AuditionPracticePlanSection(items: items,
                                        catalog: catalog,
                                        onOpenItem: { item in sheet = .editItem(item) },
                                        onStartMock: startMock)
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        AuditionItemRow(item: item,
                                        excerpt: item.excerptId.flatMap { catalog.excerpt(id: $0) },
                                        onDetails: { sheet = .editItem(item) },
                                        onOpenExcerpt: { excerpt in pushedExcerpt = excerpt })
                    }
                    .onDelete { offsets in
                        deleteItems(offsets, in: group.items)
                    }
                    .onMove { source, destination in
                        AuditionsStore.move(group.items, from: source, to: destination, context: modelContext)
                    }
                } header: {
                    Text(group.title(showRound: showRounds))
                }
            }
            if items.isEmpty {
                emptyListSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .navigationDestination(item: $pushedExcerpt) { excerpt in
            ExcerptDetailView(excerpt: excerpt)
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .alert("Delete this audition?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteAudition() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The list and your readiness notes go with it. Nothing on the orchestra's website changes.")
        }
    }

    // MARK: Pieces

    private var emptyListSection: some View {
        Section {
            AuditionsNoteRow(symbol: "list.bullet.clipboard",
                             title: String(localized: "No list yet"),
                             detail: String(localized: "Add the repertoire with the + button: type a line, pick from the catalogue, or read it from a photo or PDF of the list — on this device only."))
        } header: {
            Text("Repertoire")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !items.isEmpty {
                EditButton()
            }
            Menu {
                Button {
                    sheet = .typeLine
                } label: {
                    Label("Type a line", systemImage: "character.cursor.ibeam")
                }
                Button {
                    sheet = .catalogue
                } label: {
                    Label("From the catalogue", systemImage: "music.note.list")
                }
                Button {
                    sheet = .importList
                } label: {
                    Label("Add from a list (photo, PDF or text)", systemImage: "doc.viewfinder")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            Menu {
                Button {
                    sheet = .editDetails
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete audition", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ which: AuditionDetailSheet) -> some View {
        switch which {
        case .editItem(let item):
            NavigationStack {
                AuditionItemEditView(item: item, audition: audition)
            }
        case .editDetails:
            NavigationStack {
                AuditionFormView(mode: .edit(audition)) { _ in }
            }
        case .typeLine:
            NavigationStack {
                AuditionTypeLineView(audition: audition)
            }
        case .catalogue:
            NavigationStack {
                AuditionCataloguePickerView(audition: audition)
            }
        case .importList:
            AuditionListImportView(audition: audition)
        case .mock(let mockItems):
            NavigationStack {
                AuditionMockSetupSheet(items: mockItems, title: title)
            }
        case .link(let url):
            ExcerptSafariView(url: url)
                .ignoresSafeArea()
        }
    }

    // MARK: Reminders

    private var remindersBinding: Binding<Bool> {
        Binding(
            get: { audition.remindersEnabled },
            set: { newValue in setReminders(newValue) }
        )
    }

    private func setReminders(_ enabled: Bool) {
        if !enabled {
            audition.remindersEnabled = false
            AuditionsStore.save(modelContext)
            AuditionReminderCenter.shared.cancel(auditionId: audition.id)
            reminderNotice = nil
            return
        }
        Task {
            let allowed: Bool = await AuditionReminderCenter.shared.ensureAuthorized()
            if allowed {
                audition.remindersEnabled = true
                AuditionsStore.save(modelContext)
                await AuditionReminderCenter.shared.reschedule(for: audition)
                reminderNotice = nil
            } else {
                audition.remindersEnabled = false
                AuditionsStore.save(modelContext)
                reminderNotice = String(localized: "Notifications are turned off for Auditioner. Allow them in the iPhone Settings app, then try again.")
            }
        }
    }

    // MARK: Actions

    private func deleteItems(_ offsets: IndexSet, in groupItems: [AuditionItem]) {
        for index in offsets where index >= 0 && index < groupItems.count {
            AuditionsStore.delete(groupItems[index], context: modelContext)
        }
    }

    private func deleteAudition() {
        AuditionReminderCenter.shared.cancel(auditionId: audition.id)
        AuditionsStore.delete(audition, context: modelContext)
        dismiss()
    }

    private func startMock() {
        let sources: [AuditionMockLogic.Source] = items.map { item in
            let excerpt: Excerpt? = item.excerptId.flatMap { catalog.excerpt(id: $0) }
            return AuditionMockLogic.Source(rawText: item.rawText,
                                            excerptId: item.excerptId,
                                            category: item.category,
                                            excerptTitle: excerpt.map { AuditionBuilder.itemTitle(for: $0) })
        }
        let mockItems: [MockAuditionItem] = AuditionMockLogic.mockItems(sources)
        guard !mockItems.isEmpty else { return }
        sheet = .mock(mockItems)
    }
}
