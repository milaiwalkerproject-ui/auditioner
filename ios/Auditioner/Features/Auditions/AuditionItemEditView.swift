import SwiftUI
import SwiftData

/// Edit one line of the checklist: the text, round and kind, the catalogue link, readiness, tempi, last practised.
/// Changes are kept in local state and written when the player taps Done.
struct AuditionItemEditView: View {
    let item: AuditionItem
    let audition: Audition

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @State private var text: String
    @State private var round: String
    @State private var category: AuditionItemCategory
    @State private var readiness: Int?
    @State private var targetText: String
    @State private var achievedText: String
    @State private var hasPractised: Bool
    @State private var practisedAt: Date
    @State private var excerptId: String?
    @State private var confirmRemove: Bool = false

    init(item: AuditionItem, audition: Audition) {
        self.item = item
        self.audition = audition
        _text = State(initialValue: item.rawText)
        _round = State(initialValue: AuditionRounds.canonical(item.round))
        _category = State(initialValue: AuditionItemCategory(raw: item.category))
        _readiness = State(initialValue: item.readiness)
        _targetText = State(initialValue: AuditionTempo.text(item.targetBPM))
        _achievedText = State(initialValue: AuditionTempo.text(item.achievedBPM))
        _hasPractised = State(initialValue: item.lastPractisedAt != nil)
        _practisedAt = State(initialValue: item.lastPractisedAt ?? Date())
        _excerptId = State(initialValue: item.excerptId)
    }

    private var excerpt: Excerpt? {
        excerptId.flatMap { catalog.excerpt(id: $0) }
    }

    /// The three usual rounds plus whatever this item already says.
    private var roundChoices: [String] {
        var choices: [String] = AuditionRounds.choices
        if !choices.contains(round) {
            choices.append(round)
        }
        return choices
    }

    /// Search words for the match picker: the line without bar numbers and movement words.
    private var matchQuery: String {
        AuditionListMatcher.queryText(for: AuditionListParser.analyzed(ParsedListItem(rawText: text)))
    }

    var body: some View {
        Form {
            lineSection
            catalogueSection
            readinessSection
            tempoSection
            practisedSection
            removeSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Remove this line?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var lineSection: some View {
        Section {
            TextField("Line as printed on the list", text: $text, axis: .vertical)
                .lineLimit(1...4)
            Picker(selection: $round) {
                ForEach(roundChoices, id: \.self) { choice in
                    Text(AuditionRounds.displayName(choice)).tag(choice)
                }
            } label: {
                Text("Round")
            }
            Picker(selection: $category) {
                ForEach(AuditionItemCategory.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            } label: {
                Text("Kind")
            }
        } header: {
            Text("On the list")
        }
    }

    private var catalogueSection: some View {
        Section {
            if let excerpt = excerpt {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AuditionBuilder.itemTitle(for: excerpt))
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                    if let range = excerpt.typicalTempo?.verifiedValue {
                        HStack(spacing: 8) {
                            Text("Typical tempo \(TempoSymbols.text(for: range))")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSoft)
                            SourceLink(url: excerpt.typicalTempo?.sourceURL)
                        }
                    }
                }
                NavigationLink {
                    ExcerptDetailView(excerpt: excerpt)
                } label: {
                    Label("Open excerpt page", systemImage: "music.note.list")
                }
                NavigationLink {
                    matchPicker
                } label: {
                    Label("Change the match", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    excerptId = nil
                } label: {
                    Label("Unlink", systemImage: "link.badge.plus")
                }
            } else {
                NavigationLink {
                    matchPicker
                } label: {
                    Label("Match to catalogue", systemImage: "link")
                }
            }
        } header: {
            Text("Catalogue excerpt")
        } footer: {
            if excerpt == nil {
                Text("Linking a line to the catalogue gives you its excerpt page, reference audio and recordings. You choose the match.")
            }
        }
    }

    private var matchPicker: some View {
        AuditionMatchPickerView(instrument: audition.instrument, initialQuery: matchQuery) { chosen in
            excerptId = chosen.id
        }
    }

    private var readinessSection: some View {
        Section {
            HStack {
                RatingStars(rating: $readiness, font: .title2)
                Spacer()
                Text(AuditionReadiness.word(for: readiness))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        } header: {
            Text("Readiness")
        } footer: {
            Text("1 not started · 3 under tempo · 5 audition-ready. Tap the same star again to clear.")
        }
    }

    private var tempoSection: some View {
        Section {
            HStack {
                Text("Target")
                Spacer()
                TextField("BPM", text: $targetText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            HStack {
                Text("Achieved")
                Spacer()
                TextField("BPM", text: $achievedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
        } header: {
            Text("Tempo (beats per minute)")
        } footer: {
            Text("Your own numbers. The catalogue's typical tempo, when it is verified, is shown above.")
        }
    }

    private var practisedSection: some View {
        Section {
            Toggle("Practised at least once", isOn: $hasPractised)
            if hasPractised {
                DatePicker("Last practised", selection: $practisedAt, in: ...Date(), displayedComponents: .date)
            }
            Button {
                hasPractised = true
                practisedAt = Date()
            } label: {
                Label("Practised today", systemImage: "checkmark.circle")
            }
        } header: {
            Text("Last practised")
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Remove from the list", systemImage: "trash")
            }
        }
    }

    // MARK: Actions

    private func save() {
        let cleaned: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        item.rawText = cleaned
        item.round = AuditionRounds.canonical(round)
        item.category = category.rawValue
        item.excerptId = AuditionBuilder.cleanExcerptId(excerptId)
        item.readiness = AuditionReadiness.clamp(readiness)
        item.targetBPM = AuditionTempo.parse(targetText)
        item.achievedBPM = AuditionTempo.parse(achievedText)
        item.lastPractisedAt = hasPractised ? practisedAt : nil
        AuditionsStore.save(modelContext)
        dismiss()
    }

    private func remove() {
        AuditionsStore.delete(item, context: modelContext)
        dismiss()
    }
}
