import SwiftUI

/// "Popular with cello players" in the Excerpts browser (PLAN D6): what players who share practised
/// in the last eight weeks, as tiers only, never counts. Shown only to players who share (which
/// needs the 18+ confirmation) and kept apart from "Most asked for your chair" — its own section,
/// its own footer, its own pill colour.
struct PopularSection: View {
    let instrument: Instrument
    /// The catalogue on this device for `instrument`; excerpts the server names that aren't in it are skipped.
    let pool: [Excerpt]

    @AppStorage(TrendsSettings.sharingKey) private var sharing: Bool = false
    @AppStorage(TrendsSettings.adultConfirmedKey) private var adultConfirmed: Bool = false
    @ObservedObject private var service: TrendsService = TrendsService.shared

    var body: some View {
        if TrendsSettings.showsPopularity(sharing: sharing, adultConfirmed: adultConfirmed) {
            Section {
                rows
            } header: {
                // The refresh hangs off the header (a plain view) so the Section stays a Section for the List.
                Text(TrendsCopy.sectionTitle(for: instrument))
                    .task(id: instrument) {
                        await refresh()
                    }
            } footer: {
                Text(TrendsCopy.sectionFooter)
            }
        }
    }

    private var answer: TrendsAnswer? {
        service.answer(for: instrument)
    }

    private var entries: [PopularEntry] {
        TrendsLogic.entries(answer, in: pool)
    }

    @ViewBuilder
    private var rows: some View {
        if let answer = answer {
            if !answer.enough {
                quietLine(TrendsCopy.notEnough)
            } else if entries.isEmpty {
                quietLine(TrendsCopy.nothingStandsOut)
            } else {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.excerpt.id) {
                        PopularRow(entry: entry)
                    }
                }
            }
        } else if let note = service.note(for: instrument) {
            quietLine(note)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(TrendsCopy.checking)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.inkSoft)
    }

    private func refresh() async {
        await service.refresh(instrument: instrument, client: APIClient.fromSettings())
    }
}

/// One popular excerpt: title, subtitle and its tier pill.
struct PopularRow: View {
    let entry: PopularEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.excerpt.workHeading)
                .font(Theme.displayFont(.headline))
                .foregroundStyle(Theme.ink)
            Text(entry.excerpt.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            TrendTierPill(tier: entry.tier)
                .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }
}

/// "Very popular" / "Popular" — teal, so it never reads as an orchestra-list tier (those are brass).
struct TrendTierPill: View {
    let tier: TrendTier

    var body: some View {
        TagPill(text: tier.displayName, color: Theme.teal)
    }
}

/// One quiet line on the excerpt page, in its own row — never inside "How often it's asked" (D6).
/// Nothing is drawn unless the player shares and the server named this excerpt.
struct PopularBadgeRow: View {
    let excerpt: Excerpt

    @AppStorage(TrendsSettings.sharingKey) private var sharing: Bool = false
    @AppStorage(TrendsSettings.adultConfirmedKey) private var adultConfirmed: Bool = false
    @ObservedObject private var service: TrendsService = TrendsService.shared

    var body: some View {
        if TrendsSettings.showsPopularity(sharing: sharing, adultConfirmed: adultConfirmed),
           let tier = service.tier(for: excerpt.id, instrument: excerpt.instrument) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TrendTierPill(tier: tier)
                Text(TrendsCopy.badgeText(for: excerpt.instrument))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
