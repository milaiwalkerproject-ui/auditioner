import SwiftUI
import SwiftData

/// Wraps a config for `fullScreenCover(item:)`.
struct MockAuditionRunRequest: Identifiable {
    let id = UUID()
    let config: MockAuditionConfig
}

/// Choose the excerpts and the rules, then start a mock audition.
struct MockAuditionSetupView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.instrument) private var instrumentRaw: String = Instrument.cello.rawValue
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false
    @Query(sort: \ScoreRecord.createdAt, order: .reverse) private var records: [ScoreRecord]

    @State private var chosen: [MockAuditionItem] = []
    @State private var order: MockAuditionOrder = .asListed
    @State private var hideTitles: Bool = true
    @State private var prepSeconds: Int = 15
    @State private var recordWholeRun: Bool = true
    @State private var runRequest: MockAuditionRunRequest? = nil

    private var instrument: Instrument {
        Instrument(rawValue: instrumentRaw) ?? .cello
    }

    private var instrumentExcerpts: [Excerpt] {
        catalog.excerpts(for: instrument, includeDrafts: reviewerMode)
    }

    var body: some View {
        Form {
            excerptsSection
            rulesSection
            startSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Mock audition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .fullScreenCover(item: $runRequest) { request in
            MockAuditionRunView(config: request.config)
        }
    }

    // MARK: Sections

    private var excerptsSection: some View {
        Section {
            if chosen.isEmpty {
                Text("Pick at least one excerpt.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(Array(chosen.enumerated()), id: \.offset) { pair in
                Text(pair.element.title)
                    .lineLimit(2)
            }
            .onDelete { offsets in
                chosen.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                chosen.move(fromOffsets: source, toOffset: destination)
            }
            NavigationLink {
                MockExcerptPickerView(excerpts: instrumentExcerpts, chosen: $chosen)
            } label: {
                Label("Add from the catalogue", systemImage: "music.note.list")
            }
            if !records.isEmpty {
                NavigationLink {
                    MockScorePickerView(records: records, chosen: $chosen)
                } label: {
                    Label("Add from my reference audio", systemImage: "waveform")
                }
            }
        } header: {
            Text("Excerpts (\(chosen.count))")
        }
    }

    private var rulesSection: some View {
        Section {
            Picker(selection: $order) {
                ForEach(MockAuditionOrder.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            } label: {
                Text("Order")
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $hideTitles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behind the screen")
                    Text("Titles are hidden: you only see “Excerpt 2 of 6”.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Time to prepare between excerpts")
                Picker(selection: $prepSeconds) {
                    ForEach(MockAuditionLogic.prepChoices, id: \.self) { seconds in
                        Text(MockAuditionSetupView.prepLabel(seconds)).tag(seconds)
                    }
                } label: {
                    Text("Time to prepare")
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $recordWholeRun) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record the whole run")
                    Text("One continuous recording, with the start of each excerpt marked.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        } header: {
            Text("Rules")
        }
    }

    private var startSection: some View {
        Section {
            Button {
                start()
            } label: {
                Label("Start mock audition", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .disabled(chosen.isEmpty)
        }
    }

    // MARK: Actions

    private func start() {
        guard !chosen.isEmpty else { return }
        let items = MockAuditionLogic.ordered(chosen, order: order)
        let config = MockAuditionConfig(items: items, hideTitles: hideTitles, prepSeconds: prepSeconds, recordWholeRun: recordWholeRun)
        runRequest = MockAuditionRunRequest(config: config)
    }

    static func prepLabel(_ seconds: Int) -> String {
        seconds == 0 ? String(localized: "None") : String(localized: "\(seconds) s")
    }
}

// MARK: - Pickers

/// Multi-select from the catalogue for the user's instrument.
struct MockExcerptPickerView: View {
    let excerpts: [Excerpt]
    @Binding var chosen: [MockAuditionItem]
    @State private var query: String = ""

    private var filtered: [Excerpt] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return excerpts }
        return excerpts.filter { excerpt in
            let text = "\(excerpt.composer) \(excerpt.work) \(excerpt.title) \(excerpt.catalogueNumber ?? "")"
            return text.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if excerpts.isEmpty {
                Text("The catalogue has nothing for your instrument yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(ExcerptBrowserLogic.group(filtered)) { section in
                Section(section.title) {
                    ForEach(section.excerpts) { excerpt in
                        Button {
                            toggle(excerpt)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(excerpt.workHeading)
                                        .foregroundStyle(Theme.ink)
                                    Text(excerpt.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.inkSoft)
                                }
                                Spacer()
                                if isChosen(excerpt) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.teal)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChosen(excerpt) ? .isSelected : [])
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: Text("Composer, work or excerpt"))
        .navigationTitle("Catalogue")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isChosen(_ excerpt: Excerpt) -> Bool {
        chosen.contains { $0.excerptId == excerpt.id && $0.scoreId == nil }
    }

    private func toggle(_ excerpt: Excerpt) {
        if let index = chosen.firstIndex(where: { $0.excerptId == excerpt.id && $0.scoreId == nil }) {
            chosen.remove(at: index)
        } else {
            chosen.append(MockAuditionItem(title: "\(excerpt.workHeading) — \(excerpt.subtitle)", excerptId: excerpt.id))
        }
    }
}

/// Multi-select from the user's saved reference audio.
struct MockScorePickerView: View {
    let records: [ScoreRecord]
    @Binding var chosen: [MockAuditionItem]

    var body: some View {
        List {
            ForEach(records) { record in
                Button {
                    toggle(record)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .foregroundStyle(Theme.ink)
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.inkSoft)
                        }
                        Spacer()
                        if isChosen(record) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.teal)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen(record) ? .isSelected : [])
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My reference audio")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isChosen(_ record: ScoreRecord) -> Bool {
        chosen.contains { $0.scoreId == record.id }
    }

    private func toggle(_ record: ScoreRecord) {
        if let index = chosen.firstIndex(where: { $0.scoreId == record.id }) {
            chosen.remove(at: index)
        } else {
            chosen.append(MockAuditionItem(title: record.title, excerptId: record.excerptId, scoreId: record.id))
        }
    }
}
