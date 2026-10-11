import SwiftUI
import SwiftData

/// After a mock audition: listen back (jump to each excerpt), rate each one and the whole run, add notes.
struct MockAuditionReviewView: View {
    @Bindable var run: MockAuditionRun
    var onDone: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @StateObject private var player = TakePlayer()
    @State private var items: [MockAuditionItem] = []
    @State private var loaded: Bool = false

    private var hasRecording: Bool {
        TakeStore.recordingURL(for: run) != nil
    }

    var body: some View {
        List {
            if hasRecording {
                Section {
                    TakePlayerControls(player: player)
                } header: {
                    Text("Recording")
                }
            }
            Section {
                ForEach(items.indices, id: \.self) { index in
                    MockReviewRow(index: index,
                                  item: items[index],
                                  canJump: hasRecording,
                                  onJump: { jump(to: items[index]) },
                                  rating: ratingBinding(index))
                }
            } header: {
                Text("Excerpts")
            } footer: {
                if let average = MockAuditionLogic.averageRating(items) {
                    Text("Average \(String(format: "%.1f", average)) of 5")
                }
            }
            Section {
                HStack {
                    Text("Overall")
                    Spacer()
                    RatingStars(rating: $run.overallRating)
                }
                TextEditor(text: $run.notes)
                    .frame(minHeight: 90)
            } header: {
                Text("Your verdict")
            }
            Section {
                LabeledContent {
                    TimeText(seconds: run.totalSeconds)
                } label: {
                    Text("Total time")
                }
                LabeledContent {
                    Text(run.createdAt.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Text("Date")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onDone != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        onDone?()
                    }
                }
            }
        }
        .onAppear(perform: loadIfNeeded)
        .onDisappear {
            player.stop()
            save()
        }
    }

    // MARK: Actions

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        items = MockAuditionLogic.decode(run.itemsData)
        if let url = TakeStore.recordingURL(for: run) {
            player.load(takeURL: url)
        }
    }

    private func ratingBinding(_ index: Int) -> Binding<Int?> {
        Binding(
            get: { index < items.count ? items[index].rating : nil },
            set: { newValue in
                guard index < items.count else { return }
                items[index].rating = MockAuditionLogic.clampRating(newValue)
                run.itemsData = MockAuditionLogic.encode(items)
            }
        )
    }

    private func jump(to item: MockAuditionItem) {
        player.play(from: item.startOffsetSeconds ?? 0)
    }

    private func save() {
        run.itemsData = MockAuditionLogic.encode(items)
        try? modelContext.save()
    }
}

struct MockReviewRow: View {
    let index: Int
    let item: MockAuditionItem
    let canJump: Bool
    let onJump: () -> Void
    @Binding var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if canJump {
                    Button(action: onJump) {
                        Image(systemName: "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Play from this excerpt"))
                }
            }
            HStack {
                if let start = item.startOffsetSeconds {
                    Text("Starts at \(MediaTimeFormatter.mmss(start))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                RatingStars(rating: $rating, font: .body)
            }
        }
        .padding(.vertical, 4)
    }
}
