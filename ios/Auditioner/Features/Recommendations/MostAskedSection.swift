import SwiftUI

/// "Most asked for your chair" at the top of the Excerpts browser (PLAN D5): the five excerpts
/// most often on the lists we've collected, each with its plain-words evidence line, a tier pill
/// only once there are enough lists, and "On N open auditions now" when the server says so.
struct MostAskedSection: View {
    let entries: [MostAskedEntry]
    let local: LocalRecommendationResult?
    let source: RecommendationSource
    let isLoading: Bool
    let serverNote: String?
    @Binding var includeAllChairs: Bool
    let onHowItWorks: () -> Void

    var body: some View {
        Section {
            rows
            Toggle(isOn: $includeAllChairs) {
                Text("Include all chairs")
            }
        } header: {
            header
        } footer: {
            MostAskedFooter(local: local, source: source, serverNote: serverNote, showsNotes: source == .catalogue)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if entries.isEmpty {
            emptyRow
        } else {
            ForEach(entries) { entry in
                NavigationLink(value: entry.excerpt.id) {
                    MostAskedRow(entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        if isLoading && local == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("Counting lists…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        } else {
            Text(emptyText)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var emptyText: String {
        guard let local = local else {
            return String(localized: "We haven't collected any lists for your chair yet.")
        }
        return LocalRecommendationEngine.evidenceText(listCount: 0, totalLists: 0,
                                                      instrument: local.query.instrument,
                                                      position: local.query.position,
                                                      includeAllChairs: local.query.includeAllChairs,
                                                      years: nil)
    }

    private var header: some View {
        HStack {
            Text("Most asked for your chair")
            Spacer(minLength: 8)
            Button {
                onHowItWorks()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("How is this worked out?"))
        }
    }
}

/// One of the most-asked excerpts: title, evidence line, and the pills the honesty contract allows.
struct MostAskedRow: View {
    let entry: MostAskedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.excerpt.workHeading)
                .font(Theme.displayFont(.headline))
                .foregroundStyle(Theme.ink)
            Text(entry.excerpt.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            Text(entry.item.evidence)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            pills
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var pills: some View {
        if entry.item.tier != nil || (entry.item.openNow ?? 0) > 0 {
            HStack(spacing: 6) {
                if let tier = entry.item.tier {
                    TagPill(text: tier.displayName, color: Theme.brass)
                }
                if let openNow = entry.item.openNow, openNow > 0 {
                    OpenNowBadge(count: openNow)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// "On N open auditions now" — kept apart from the frequency (PLAN D5).
struct OpenNowBadge: View {
    let count: Int

    var body: some View {
        TagPill(text: RecommendationMerge.openNowText(count), color: Theme.garnet)
    }
}

/// Where the counts come from and the caveats, in plain words.
struct MostAskedFooter: View {
    let local: LocalRecommendationResult?
    let source: RecommendationSource
    let serverNote: String?
    /// The catalogue's caveats apply only when the catalogue is what's shown.
    let showsNotes: Bool

    private var lines: [String] {
        var result: [String] = [source.label]
        if showsNotes, let local = local {
            result.append(contentsOf: local.notes)
            if let note = LocalRecommendationEngine.notEnoughListsNote(totalLists: local.totalLists) {
                result.append(note)
            }
        }
        if let serverNote = serverNote, !serverNote.isEmpty {
            result.append(serverNote)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { index in
                Text(lines[index])
            }
        }
    }
}
