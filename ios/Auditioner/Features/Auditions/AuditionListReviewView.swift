import SwiftUI

/// Which review line the match picker is open for.
struct AuditionReviewPick: Identifiable, Hashable {
    let id: UUID
}

/// The player checks every parsed line before it becomes part of the list: keep or drop it, fix the
/// words, confirm or change the catalogue link. Scores are shown so a weak guess looks weak.
struct AuditionListReviewView: View {
    @Binding var lines: [AuditionReviewLine]
    let instrument: Instrument
    let pool: [Excerpt]
    let onConfirm: () -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @State private var pick: AuditionReviewPick? = nil

    private var includedCount: Int {
        AuditionReviewLogic.includedCount(lines)
    }

    var body: some View {
        List {
            Section {
                Text("Tick the lines to keep, fix any misread words, and confirm the catalogue link for each. Nothing is saved until you add them.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach($lines) { $line in
                AuditionReviewLineRow(line: $line,
                                      pool: pool,
                                      excerptTitle: { id in catalog.excerpt(id: id).map { AuditionBuilder.itemTitle(for: $0) } },
                                      onPick: { pick = AuditionReviewPick(id: line.id) })
            }
            Section {
                Button {
                    onConfirm()
                } label: {
                    Label(confirmTitle, systemImage: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(includedCount == 0)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationDestination(item: $pick) { request in
            AuditionMatchPickerView(instrument: instrument, initialQuery: queryText(for: request.id)) { excerpt in
                setChosen(excerpt.id, for: request.id)
            }
        }
    }

    private var confirmTitle: String {
        includedCount == 1 ? String(localized: "Add 1 item") : String(localized: "Add \(includedCount) items")
    }

    private func queryText(for lineId: UUID) -> String {
        guard let line = lines.first(where: { $0.id == lineId }) else { return "" }
        return AuditionListMatcher.queryText(for: line.parsed)
    }

    private func setChosen(_ excerptId: String, for lineId: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineId }) else { return }
        lines[index].chosenExcerptId = excerptId
        if !lines[index].candidates.contains(where: { $0.excerptId == excerptId }) {
            lines[index].candidates.insert(AuditionMatchCandidate(excerptId: excerptId, score: 1), at: 0)
        }
    }
}

/// One line under review.
struct AuditionReviewLineRow: View {
    @Binding var line: AuditionReviewLine
    let pool: [Excerpt]
    let excerptTitle: (String) -> String?
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    line.include.toggle()
                } label: {
                    Image(systemName: line.include ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(line.include ? Theme.teal : Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(line.include ? "Keep this line" : "Line left out"))
                TextField("Line", text: $line.text, axis: .vertical)
                    .lineLimit(1...4)
                    .foregroundStyle(line.include ? Theme.ink : Theme.inkFaint)
            }
            tags
            if line.include {
                matchView
            }
        }
        .padding(.vertical, 4)
        .onChange(of: line.text) { _, _ in
            line = AuditionReviewLogic.rematched(line, pool: pool)
        }
    }

    @ViewBuilder
    private var tags: some View {
        let round: String = AuditionRounds.canonical(line.round)
        let category: AuditionItemCategory = AuditionItemCategory(raw: line.category)
        if !round.isEmpty || category != .excerpt {
            HStack(spacing: 6) {
                if !round.isEmpty {
                    TagPill(text: AuditionRounds.displayName(round), color: Theme.slate)
                }
                if category != .excerpt {
                    TagPill(text: category.displayName, color: Theme.brass)
                }
            }
        }
    }

    @ViewBuilder
    private var matchView: some View {
        if let chosen = line.chosenExcerptId {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.teal)
                Text(excerptTitle(chosen) ?? chosen)
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Button("Unlink") {
                    line.chosenExcerptId = nil
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        } else if line.candidates.isEmpty {
            HStack {
                Text("No catalogue match")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 4)
                Button("Find…") { onPick() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(line.candidates) { candidate in
                    Button {
                        line.chosenExcerptId = candidate.excerptId
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle")
                                .foregroundStyle(Theme.inkFaint)
                            Text(excerptTitle(candidate.excerptId) ?? candidate.excerptId)
                                .font(.caption)
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text(AuditionListMatcher.percentText(candidate.score))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(candidate.score >= AuditionListMatcher.strongThreshold ? Theme.teal : Theme.inkSoft)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Other excerpt…") { onPick() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }
}
