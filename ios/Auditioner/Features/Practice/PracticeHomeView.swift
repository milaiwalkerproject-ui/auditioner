import SwiftUI
import SwiftData

/// Practice tab home: the tools, the demo and saved reference audio.
struct PracticeHomeView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScoreRecord.createdAt, order: .reverse) private var records: [ScoreRecord]

    var body: some View {
        NavigationStack {
            List {
                toolsSection
                demoSection
                referenceSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Practice")
        }
    }

    // MARK: Sections

    private var toolsSection: some View {
        Section {
            NavigationLink {
                MetronomeView()
            } label: {
                PracticeToolRow(title: String(localized: "Metronome"),
                                detail: String(localized: "Subdivisions, accents, tap tempo."),
                                systemImage: "metronome",
                                color: Theme.garnet)
            }
            NavigationLink {
                DroneView()
            } label: {
                PracticeToolRow(title: String(localized: "Drone"),
                                detail: String(localized: "A sustained note to tune and play against."),
                                systemImage: "tuningfork",
                                color: Theme.teal)
            }
            NavigationLink {
                MockAuditionSetupView()
            } label: {
                PracticeToolRow(title: String(localized: "Mock audition"),
                                detail: String(localized: "Random order, hidden titles, one recording, self-rating."),
                                systemImage: "music.mic",
                                color: Theme.brass)
            }
            NavigationLink {
                TakesListView()
            } label: {
                PracticeToolRow(title: String(localized: "My recordings"),
                                detail: String(localized: "Takes and mock auditions: listen, rate, share."),
                                systemImage: "waveform",
                                color: Theme.slate)
            }
        } header: {
            Text("Tools")
        }
    }

    private var demoSection: some View {
        Section {
            Button {
                openDemo()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(Theme.brass)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Try the demo")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("A short scale to try the tempo slider, loop, count-in, tuning and record & compare.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.garnet)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ScoreDocument.demoScale() == nil)
        }
    }

    private var referenceSection: some View {
        Section {
            if records.isEmpty {
                Text("Nothing saved yet. Scan a part from an excerpt page or from My parts to make reference audio.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(records) { record in
                    Button {
                        router.openPractice(record.document)
                    } label: {
                        PracticeRecordRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteRecords)
            }
        } header: {
            Text("Your reference audio")
        }
    }

    // MARK: Actions

    private func openDemo() {
        guard let demo = ScoreDocument.demoScale() else { return }
        router.openPractice(demo)
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets where index >= 0 && index < records.count {
            modelContext.delete(records[index])
        }
        try? modelContext.save()
    }
}

// MARK: - Rows

private struct PracticeToolRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PracticeRecordRow: View {
    let record: ScoreRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    TagPill(text: PracticeRecordRow.originText(record.origin),
                            color: PracticeRecordRow.originColor(record.origin))
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.inkFaint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    static func originText(_ origin: ScoreOrigin) -> String {
        switch origin {
        case .demo: return String(localized: "Demo")
        case .omr: return String(localized: "Read from your scan")
        case .edited: return String(localized: "Corrected by you")
        case .curated: return String(localized: "Checked")
        }
    }

    static func originColor(_ origin: ScoreOrigin) -> Color {
        switch origin {
        case .demo: return Theme.slate
        case .omr: return Theme.garnet
        case .edited: return Theme.teal
        case .curated: return Theme.brass
        }
    }
}
