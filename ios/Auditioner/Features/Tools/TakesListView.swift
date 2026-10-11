import SwiftUI
import SwiftData

/// "My recordings": practice takes and mock-audition runs.
struct TakesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeTake.createdAt, order: .reverse) private var takes: [PracticeTake]
    @Query(sort: \MockAuditionRun.createdAt, order: .reverse) private var runs: [MockAuditionRun]

    var body: some View {
        List {
            takesSection
            runsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("My recordings")
    }

    private var takesSection: some View {
        Section {
            if takes.isEmpty {
                Text("Nothing recorded yet. Use Record in the practice player, or record a mock audition.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(takes) { take in
                    NavigationLink {
                        TakeDetailView(take: take)
                    } label: {
                        TakeRow(take: take)
                    }
                }
                .onDelete(perform: deleteTakes)
            }
        } header: {
            Text("Recordings")
        }
    }

    private var runsSection: some View {
        Section {
            if runs.isEmpty {
                Text("No mock auditions yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(runs) { run in
                    NavigationLink {
                        MockAuditionReviewView(run: run)
                    } label: {
                        MockRunRow(run: run)
                    }
                }
                .onDelete(perform: deleteRuns)
            }
        } header: {
            Text("Mock auditions")
        }
    }

    private func deleteTakes(at offsets: IndexSet) {
        let doomed: [PracticeTake] = offsets.compactMap { $0 < takes.count ? takes[$0] : nil }
        for take in doomed {
            TakeStore.delete(take, context: modelContext)
        }
    }

    private func deleteRuns(at offsets: IndexSet) {
        let doomed: [MockAuditionRun] = offsets.compactMap { $0 < runs.count ? runs[$0] : nil }
        for run in doomed {
            TakeStore.delete(run, context: modelContext)
        }
    }
}

// MARK: - Rows

struct TakeRow: View {
    let take: PracticeTake

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(take.title.isEmpty ? String(localized: "Untitled take") : take.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text(MediaTimeFormatter.mmss(take.durationSeconds))
                        .monospacedDigit()
                    if let rating = take.selfRating {
                        Text("★ \(rating)")
                            .foregroundStyle(Theme.brass)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MockRunRow: View {
    let run: MockAuditionRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.mic")
                .foregroundStyle(Theme.garnet)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(MockAuditionLogic.decode(run.itemsData).count) excerpts")
                    Text(MediaTimeFormatter.mmss(run.totalSeconds))
                        .monospacedDigit()
                    if let rating = run.overallRating {
                        Text("★ \(rating)")
                            .foregroundStyle(Theme.brass)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Take detail

struct TakeDetailView: View {
    @Bindable var take: PracticeTake
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = TakePlayer()
    @State private var confirmDelete: Bool = false

    var body: some View {
        Form {
            Section {
                TakePlayerControls(player: player)
            }
            Section {
                TextField("Title", text: $take.title)
                LabeledContent {
                    Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Text("Recorded")
                }
                LabeledContent {
                    TimeText(seconds: take.durationSeconds)
                } label: {
                    Text("Length")
                }
                if let bpm = take.referenceBPM {
                    LabeledContent {
                        Text("♩ = \(Int(bpm.rounded()))")
                    } label: {
                        Text("Reference tempo")
                    }
                }
            } header: {
                Text("About this take")
            }
            Section {
                RatingStars(rating: $take.selfRating)
            } header: {
                Text("Your rating")
            }
            Section {
                TextEditor(text: $take.notes)
                    .frame(minHeight: 100)
            } header: {
                Text("Notes")
            }
            Section {
                ShareLink(item: TakeStore.fileURL(for: take)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete recording", systemImage: "trash")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player.load(takeURL: TakeStore.fileURL(for: take))
        }
        .onDisappear {
            player.stop()
            try? modelContext.save()
        }
        .confirmationDialog(Text("Delete this recording?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(role: .destructive) {
                deleteAndClose()
            } label: {
                Text("Delete")
            }
        } message: {
            Text("The audio file is removed from this device.")
        }
    }

    /// Pops first, then deletes a moment later so the screen never shows a deleted record.
    private func deleteAndClose() {
        player.stop()
        let target = take
        let context = modelContext
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            TakeStore.delete(target, context: context)
        }
    }
}
