import SwiftUI
import SwiftData

// MARK: - Type a line

/// Add one line by typing it. The catalogue is searched as you type and the match is yours to tick.
struct AuditionTypeLineView: View {
    let audition: Audition

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @State private var text: String = ""
    @State private var round: String = ""
    @State private var category: AuditionItemCategory = .excerpt
    @State private var chosenExcerptId: String? = nil

    private var pool: [Excerpt] {
        catalog.excerpts(for: audition.instrument, includeDrafts: reviewerMode)
    }

    private var parsed: ParsedListItem {
        AuditionListParser.analyzed(ParsedListItem(rawText: text, round: round, category: category.rawValue))
    }

    private var candidates: [AuditionMatchCandidate] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return AuditionListMatcher.candidates(for: parsed, in: pool)
    }

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. Brahms – Symphony No. 2, mvt. II, mm. 1–15", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                Picker(selection: $round) {
                    ForEach(AuditionRounds.choices, id: \.self) { choice in
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
                Text("The line")
            }
            matchSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Type a line")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!canAdd)
            }
        }
        .onChange(of: text) { _, _ in
            if let chosen = chosenExcerptId, !candidates.contains(where: { $0.excerptId == chosen }) {
                chosenExcerptId = nil
            }
        }
    }

    private var matchSection: some View {
        Section {
            if candidates.isEmpty {
                Text(canAdd ? String(localized: "No catalogue match for this line yet. You can link it later.")
                            : String(localized: "Type the line to see catalogue suggestions."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(candidates) { candidate in
                if let excerpt = catalog.excerpt(id: candidate.excerptId) {
                    MatchCandidateRow(excerpt: excerpt,
                                      score: candidate.score,
                                      isChosen: chosenExcerptId == candidate.excerptId) {
                        chosenExcerptId = (chosenExcerptId == candidate.excerptId) ? nil : candidate.excerptId
                    }
                }
            }
        } header: {
            Text("Catalogue match")
        } footer: {
            Text("Tap a suggestion to link the line to that excerpt. The percentage is how well the words agree.")
        }
    }

    private func add() {
        do {
            try AuditionsStore.add(text: text, round: round, category: category, excerptId: chosenExcerptId,
                                   to: audition, context: modelContext)
            dismiss()
        } catch {
            NSLog("Auditioner: adding the line failed: %@", error.localizedDescription)
        }
    }
}

/// One proposed excerpt with its score and a tick.
struct MatchCandidateRow: View {
    let excerpt: Excerpt
    let score: Double
    let isChosen: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Theme.teal : Theme.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(excerpt.workHeading)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                    Text(excerpt.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer(minLength: 8)
                Text(AuditionListMatcher.percentText(score))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(score >= AuditionListMatcher.strongThreshold ? Theme.teal : Theme.inkSoft)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

// MARK: - From the catalogue

/// Multi-select from the catalogue for the audition's instrument; each pick becomes one line.
struct AuditionCataloguePickerView: View {
    let audition: Audition

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @State private var query: String = ""
    @State private var chosen: [String] = []

    private var excerpts: [Excerpt] {
        catalog.search(query, instrument: audition.instrument, includeDrafts: reviewerMode)
    }

    private var alreadyListed: Set<String> {
        Set(AuditionsStore.items(for: audition.id, context: modelContext).compactMap { $0.excerptId })
    }

    var body: some View {
        List {
            if excerpts.isEmpty {
                Text("Nothing in the \(audition.instrument.displayName.lowercased()) catalogue matches.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(ExcerptBrowserLogic.group(excerpts)) { section in
                Section(section.title) {
                    ForEach(section.excerpts) { excerpt in
                        row(excerpt)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .searchable(text: $query, prompt: Text("Composer, work or excerpt"))
        .navigationTitle("From the catalogue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(addTitle) { addChosen() }
                    .disabled(chosen.isEmpty)
            }
        }
    }

    private var addTitle: String {
        chosen.isEmpty ? String(localized: "Add") : String(localized: "Add \(chosen.count)")
    }

    private func row(_ excerpt: Excerpt) -> some View {
        let listed: Bool = alreadyListed.contains(excerpt.id)
        let picked: Bool = chosen.contains(excerpt.id)
        return Button {
            toggle(excerpt)
        } label: {
            HStack {
                ExcerptRow(excerpt: excerpt, reviewerMode: reviewerMode)
                Spacer(minLength: 8)
                if listed {
                    Text("On the list")
                        .font(.caption)
                        .foregroundStyle(Theme.inkFaint)
                } else if picked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.teal)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(listed)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func toggle(_ excerpt: Excerpt) {
        if let index = chosen.firstIndex(of: excerpt.id) {
            chosen.remove(at: index)
        } else {
            chosen.append(excerpt.id)
        }
    }

    private func addChosen() {
        for excerptId in chosen {
            guard let excerpt = catalog.excerpt(id: excerptId) else { continue }
            do {
                try AuditionsStore.add(excerpt: excerpt, to: audition, context: modelContext)
            } catch {
                NSLog("Auditioner: adding %@ to the audition failed: %@", excerptId, error.localizedDescription)
            }
        }
        dismiss()
    }
}
