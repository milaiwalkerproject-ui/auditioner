import SwiftUI

// Sections of the excerpt page. Each one is small on purpose so the SwiftUI type-checker
// stays fast and each piece can be reused in the iPhone and iPad layouts.

// MARK: - Header

struct ExcerptHeaderSection: View {
    let excerpt: Excerpt
    let reviewerMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(excerpt.composer)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            Text(workLine)
                .font(Theme.displayFont(.title2))
                .foregroundStyle(Theme.ink)
            if let movement = ExcerptFormat.movementLine(excerpt.movement) {
                Text(movement)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
            }
            Text(excerpt.title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            positionsLine
            pills
            if let checked = excerpt.lastVerified, !checked.isEmpty {
                Text("Last checked \(ExcerptFormat.displayDate(checked))")
                    .font(.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workLine: String {
        if let number = excerpt.catalogueNumber, !number.isEmpty {
            return "\(excerpt.work), \(number)"
        }
        return excerpt.work
    }

    @ViewBuilder
    private var positionsLine: some View {
        let names: [String] = excerpt.positions.map { $0.displayName }
        if !names.isEmpty {
            Text(names.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var pills: some View {
        HStack(spacing: 6) {
            if let tier = excerpt.frequency?.verifiedTier {
                TagPill(text: tier.displayName, color: Theme.brass)
            }
            if let difficulty = excerpt.difficulty, difficulty.reviewStatus == .approved {
                TagPill(text: ExcerptFormat.difficultyLabel(difficulty.value), color: Theme.slate)
            }
            if excerpt.provenanceType == "imported" {
                TagPill(text: String(localized: "Imported — bars not yet checked"), color: Theme.teal)
            }
            if reviewerMode && excerpt.listingStatus != .published {
                TagPill(text: String(localized: "Draft"), color: Theme.garnet)
            }
        }
    }
}

// MARK: - Actions

struct ExcerptActionsSection: View {
    let excerpt: Excerpt
    let onOpenIMSLP: (URL) -> Void
    let onReferenceMissing: () -> Void

    @EnvironmentObject private var router: AppRouter
    @State private var showMetronome = false

    /// Start the metronome at the verified typical tempo, but only the first time:
    /// once the player has saved settings for this excerpt, those win.
    private var metronomeStartBPM: Double? {
        let key = MetronomeMath.presetKey(excerptId: excerpt.id)
        guard UserDefaults.standard.data(forKey: key) == nil else { return nil }
        return excerpt.typicalTempo?.verifiedValue?.bpmMin
    }

    var body: some View {
        ExcerptSectionBox(nil) {
            VStack(spacing: 10) {
                Button {
                    router.startScan(.camera, excerpt: excerpt)
                } label: {
                    Label("Scan my part", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 10) {
                    Button {
                        router.startScan(.files, excerpt: excerpt)
                    } label: {
                        Label("Import my part", systemImage: "doc")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        router.startScan(.photos, excerpt: excerpt)
                    } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)

                if let imslp = ExcerptLinks.imslpURL(for: excerpt) {
                    Button {
                        onOpenIMSLP(imslp)
                    } label: {
                        Label("Get the part on IMSLP", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    showMetronome = true
                } label: {
                    Label("Metronome for this excerpt", systemImage: "metronome")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let file = excerpt.referenceMusicXML, !file.isEmpty {
                    Button {
                        playReference(file)
                    } label: {
                        Label("Play reference", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showMetronome) {
            NavigationStack {
                MetronomeView(excerptId: excerpt.id, startBPM: metronomeStartBPM)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMetronome = false }
                        }
                    }
            }
        }
    }

    private func playReference(_ fileName: String) {
        let document: ScoreDocument? = ScoreDocument.bundled(named: fileName, title: excerpt.workHeading, origin: .curated,
                                             instrument: excerpt.instrument, excerptId: excerpt.id)
        if let document = document {
            router.openPractice(document)
        } else {
            onReferenceMissing()
        }
    }
}

// MARK: - Facts

struct ExcerptFactsSection: View {
    let excerpt: Excerpt

    private var barsRow: FactRow? {
        FactRow.make(String(localized: "Bars"), excerpt.location) { $0.text }
    }

    private var otherRows: [FactRow] {
        var rows: [FactRow] = []
        if let row = FactRow.make(String(localized: "Tempo marking"), excerpt.tempoMarking, italic: true, text: { $0 }) {
            rows.append(row)
        }
        if let row = FactRow.make(String(localized: "Composer's metronome"), excerpt.composerMetronome,
                                  text: { TempoSymbols.text(for: $0) }) {
            rows.append(row)
        }
        if let row = FactRow.make(String(localized: "Typical tempo"), excerpt.typicalTempo,
                                  text: { TempoSymbols.text(for: $0) }) {
            rows.append(row)
        }
        if let row = FactRow.make(String(localized: "Meter"), excerpt.meter, text: { $0 }) {
            rows.append(row)
        }
        if let row = FactRow.make(String(localized: "Key"), excerpt.key, text: { $0 }) {
            rows.append(row)
        }
        return rows
    }

    var body: some View {
        ExcerptSectionBox(Text("Facts")) {
            if let bars = barsRow {
                bars
            }
            if let variants = excerpt.variants, !variants.isEmpty {
                ExcerptVariantsRow(variants: variants)
            }
            ForEach(otherRows) { row in
                row
            }
            if let clefs = excerpt.clefs, !clefs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    FactLabel(text: String(localized: "Clefs"))
                    Text(clefs.joined(separator: ", "))
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                }
                .padding(.vertical, 2)
            }
            if let techniques = excerpt.techniques, !techniques.isEmpty {
                ExcerptTechniqueChips(techniques: techniques)
            }
        }
    }
}

/// "Other versions": bar ranges seen on real audition lists, each with its source.
struct ExcerptVariantsRow: View {
    let variants: [LocationVariant]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FactLabel(text: String(localized: "Other versions"))
            ForEach(0..<variants.count, id: \.self) { index in
                variantLine(variants[index])
            }
        }
        .padding(.vertical, 2)
    }

    private func variantLine(_ variant: LocationVariant) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ExcerptFormat.variantLine(variant))
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            SourceLink(url: URL(string: variant.source))
        }
    }
}

/// Techniques to watch, as chips.
struct ExcerptTechniqueChips: View {
    let techniques: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FactLabel(text: String(localized: "Techniques"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<techniques.count, id: \.self) { index in
                        TagPill(text: ExcerptFormat.humanizeTechnique(techniques[index]), color: Theme.teal)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Copyright

struct ExcerptCopyrightSection: View {
    let excerpt: Excerpt

    private struct Line: Identifiable {
        let id: String
        let text: String
        let url: URL?
    }

    private var regions: [(fact: Verifiable<CopyrightValue>?, region: ExcerptFormat.CopyrightRegion)] {
        let us: Verifiable<CopyrightValue>? = excerpt.copyright?.US
        let eu: Verifiable<CopyrightValue>? = excerpt.copyright?.EU
        let ca: Verifiable<CopyrightValue>? = excerpt.copyright?.CA
        return [
            (fact: us, region: ExcerptFormat.CopyrightRegion.us),
            (fact: eu, region: ExcerptFormat.CopyrightRegion.eu),
            (fact: ca, region: ExcerptFormat.CopyrightRegion.ca)
        ]
    }

    private var lines: [Line] {
        var result: [Line] = []
        for entry in regions {
            guard let fact = entry.fact, let value = fact.verifiedValue else { continue }
            result.append(Line(id: entry.region.rawValue,
                               text: ExcerptFormat.copyrightLine(value, region: entry.region),
                               url: fact.sourceURL))
        }
        return result
    }

    /// True unless every region has a verified or not-applicable status.
    private var needsWarning: Bool {
        for entry in regions {
            guard let fact = entry.fact else { return true }
            if fact.status == .unverified { return true }
        }
        return false
    }

    private var warningURL: URL? {
        for entry in regions {
            if let fact = entry.fact, fact.status == .unverified, let url = fact.sourceURL { return url }
        }
        return nil
    }

    var body: some View {
        ExcerptSectionBox(Text("Copyright")) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.text)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    SourceLink(url: line.url)
                }
            }
            if needsWarning {
                Label("Check IMSLP's copyright label for your country before downloading.",
                      systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.garnet)
                if let url = warningURL {
                    Link(destination: url) {
                        Label("IMSLP page for this work", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - How often it's asked

/// PLAN D5: the count is worked out on the device from the catalogue's evidence rows for the
/// player's chair and region (`LocalRecommendationEngine`), never from the catalogue's own tier,
/// so the number can be checked against the sources listed right under it. "On N open auditions
/// now" comes from the server when it has answered, and is kept apart from the frequency.
struct ExcerptFrequencySection: View {
    let excerpt: Excerpt

    @EnvironmentObject private var catalog: CatalogStore
    @ObservedObject private var recommendations: RecommendationService = RecommendationService.shared
    @AppStorage(SettingsKey.position) private var positionRaw: String = Position.section.rawValue
    @AppStorage(SettingsKey.region) private var region: String = ProfileOptions.defaultRegionId
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false
    /// "Include all chairs", per instrument (brass defaults to on, PLAN F5); shared with the browser.
    @ObservedObject private var chairScope: IncludeAllChairsStore = IncludeAllChairsStore.shared

    private var includeAllChairs: Bool {
        chairScope.includeAllChairs(for: excerpt.instrument)
    }

    private var evidence: [FrequencyEvidence] {
        excerpt.frequency?.evidence ?? []
    }

    /// Counted from the evidence rows of this instrument (a few thousand at most), so cheap enough to do here.
    private var summary: ExcerptAskSummary {
        let query: RecommendationQuery = RecommendationSettings.query(instrument: excerpt.instrument,
                                                                      positionRaw: positionRaw,
                                                                      region: region,
                                                                      includeAllChairs: includeAllChairs,
                                                                      includeDrafts: reviewerMode)
        return ExcerptAskSummary.make(excerptId: excerpt.id,
                                      catalogExcerpts: catalog.excerpts,
                                      query: query,
                                      openNow: recommendations.openNowCount(for: excerpt.id, instrument: excerpt.instrument))
    }

    var body: some View {
        ExcerptSectionBox(Text("How often it's asked")) {
            ExcerptAskSummaryView(summary: summary)
            Toggle(isOn: chairScope.binding(for: excerpt.instrument)) {
                Text("Include all chairs")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            }
            if !evidence.isEmpty {
                FactLabel(text: String(localized: "Where we saw it"))
                ForEach(0..<evidence.count, id: \.self) { index in
                    evidenceLine(evidence[index])
                }
            }
        }
    }

    private func evidenceLine(_ item: FrequencyEvidence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.description)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            SourceLink(url: URL(string: item.source))
        }
    }
}

/// The computed count for one excerpt: tier pill (only with enough lists), open-now badge,
/// the evidence line, the caveats and where the count comes from.
struct ExcerptAskSummaryView: View {
    let summary: ExcerptAskSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pills
            Text(summary.ask.evidence)
                .font(.body)
                .foregroundStyle(Theme.ink)
            ForEach(0..<summary.notes.count, id: \.self) { index in
                Text(summary.notes[index])
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            if let note = summary.notEnoughListsNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            Text(summary.sourceLabel)
                .font(.caption)
                .foregroundStyle(Theme.inkFaint)
        }
    }

    @ViewBuilder
    private var pills: some View {
        if summary.tier != nil || (summary.openNow ?? 0) > 0 {
            HStack(spacing: 6) {
                if let tier = summary.tier {
                    TagPill(text: tier.displayName, color: Theme.brass)
                }
                if let openNow = summary.openNow, openNow > 0 {
                    OpenNowBadge(count: openNow)
                }
            }
        }
    }
}

// MARK: - Sources

struct ExcerptSourcesSection: View {
    let excerpt: Excerpt

    var body: some View {
        if !excerpt.sources.isEmpty {
            ExcerptSectionBox(Text("Sources")) {
                ForEach(0..<excerpt.sources.count, id: \.self) { index in
                    sourceLine(excerpt.sources[index])
                }
            }
        }
    }

    @ViewBuilder
    private func sourceLine(_ source: String) -> some View {
        if let url = URL(string: source) {
            Link(destination: url) {
                Label(ExcerptFormat.hostLabel(source), systemImage: "link")
                    .font(.subheadline)
                    .lineLimit(1)
            }
        } else {
            Text(source)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}
