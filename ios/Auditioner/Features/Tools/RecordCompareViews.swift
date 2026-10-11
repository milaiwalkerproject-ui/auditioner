import SwiftUI
import SwiftData

/// Record / stop / compare controls shown under the practice transport.
struct RecordCompareBar: View {
    @ObservedObject var session: RecordCompareSession
    @ObservedObject var engine: PlaybackEngine
    let hasLastTake: Bool
    let onRecord: () -> Void
    let onStop: () -> Void
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if case .failed(let message) = session.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.garnet)
            }
            Text("Wear headphones so the microphone records only you, not the reference.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var controls: some View {
        switch session.phase {
        case .idle, .failed:
            HStack(spacing: 12) {
                Button(action: onRecord) {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .tint(Theme.garnet)
                .disabled(!engine.isReady || engine.isExporting)
                .accessibilityHint(Text("Records you while the reference plays, after a count-in when Count-in is on"))
                if hasLastTake {
                    Button(action: onCompare) {
                        Label("Compare", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Text("Record yourself with the reference, then compare.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
        case .preparing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Preparing the reference…")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 0)
            }
        case .countingIn, .recording:
            HStack(spacing: 12) {
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.garnet)
                VStack(alignment: .leading, spacing: 4) {
                    phaseLabel
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(session.phase == .countingIn ? Theme.inkSoft : Theme.garnet)
                    LevelMeterBar(level: session.inputLevel)
                }
                TimeText(seconds: session.elapsedSeconds, font: .subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}

extension RecordCompareBar {
    /// "Count-in…" / "Recording" as localizable literals.
    fileprivate var phaseLabel: Text {
        if session.phase == .countingIn {
            return Text("Count-in…")
        }
        return Text("Recording")
    }
}

/// What the compare sheet needs: the take just recorded and the reference it was recorded against.
struct CompareSheetItem: Identifiable {
    let id = UUID()
    let take: PracticeTake
    let referenceURL: URL
    let referenceOffsetSeconds: Double
}

/// "You / Reference / Both" playback of a take against the reference.
struct CompareSheet: View {
    let item: CompareSheetItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var player = TakePlayer()

    private var ratingBinding: Binding<Int?> {
        Binding(get: { item.take.selfRating }, set: { newValue in item.take.selfRating = newValue })
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Picker(selection: $player.mix) {
                    ForEach(CompareMix.allCases) { mix in
                        Text(mix.displayName).tag(mix)
                    }
                } label: {
                    Text("Listen to")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Listen to"))

                TakePlayerControls(player: player)

                HStack {
                    Text("How did it go?")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                    Spacer()
                    RatingStars(rating: ratingBinding)
                }

                Text("“Both” plays your take and the reference together from where you started, at the tempo you recorded at. Slowing down keeps them together.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            player.mix = .you
            player.load(takeURL: TakeStore.fileURL(for: item.take),
                        referenceURL: item.referenceURL,
                        referenceOffsetSeconds: item.referenceOffsetSeconds)
        }
        .onDisappear {
            player.stop()
            try? modelContext.save()
        }
        .presentationDetents([.medium, .large])
    }
}
