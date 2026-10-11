import SwiftUI
import SwiftData

/// A YouTube recording: the official embedded player, and below it (never on top of it)
/// the status line, mark buttons, speed menu, A–B loop and the "Open in YouTube" fallback.
struct YouTubeRecordingPlayer: View {
    let recording: Recording
    let excerpt: Excerpt
    let videoId: String

    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller = YouTubePlayerController()
    @StateObject private var marks: RecordingMarks
    @State private var loopEnabled: Bool = false

    init(recording: Recording, excerpt: Excerpt, videoId: String) {
        self.recording = recording
        self.excerpt = excerpt
        self.videoId = videoId
        _marks = StateObject(wrappedValue: RecordingMarks(excerpt: excerpt, recording: recording))
    }

    // MARK: Derived

    private var verifiedStart: Double? {
        recording.start?.verifiedValue
    }

    private var verifiedEnd: Double? {
        recording.end?.verifiedValue
    }

    /// One second before the verified start, because seeks snap to keyframes.
    private var cueStart: Int? {
        verifiedStart.map { MediaTimeFormatter.youtubeCueSecond(verifiedStart: $0) }
    }

    private var cueEnd: Int? {
        verifiedEnd.map { Int($0.rounded(.up)) }
    }

    private var openInYouTubeURL: URL? {
        let start: Double? = marks.start ?? verifiedStart
        return ExcerptLinks.openInYouTubeURL(videoId: videoId,
                                             startSeconds: start.map { MediaTimeFormatter.wholeSeconds($0) })
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            playerArea
            RecordingStartStatusLine(verifiedStart: verifiedStart)
            if let code = controller.errorCode {
                errorBlock(code)
            } else if let failure = controller.loadFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Theme.garnet)
            }
            jumpRow
            RecordingMarkControls(
                marks: marks,
                onMarkStart: { marks.setStart(controller.currentTime, in: modelContext) },
                onMarkEnd: { marks.setEnd(controller.currentTime, in: modelContext) },
                onJumpToStart: { jump(to: marks.start) }
            )
            controlsRow
            if controller.errorCode == nil, let url = openInYouTubeURL {
                Link("Open in YouTube", destination: url)
                    .font(.caption)
            }
        }
        .onAppear {
            marks.load(from: modelContext)
        }
        .onDisappear {
            controller.pause()
        }
        .onChange(of: controller.currentTime) { _, newValue in
            enforceLoop(newValue)
        }
    }

    // MARK: Pieces

    private var playerArea: some View {
        YouTubePlayerView(videoId: videoId, startSeconds: cueStart, endSeconds: cueEnd, controller: controller)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 200)
            .background(Color.black)
    }

    private var jumpRow: some View {
        HStack(spacing: 12) {
            if verifiedStart != nil {
                Button {
                    jump(to: cueStart.map { Double($0) })
                } label: {
                    Label("Jump to start (checked)", systemImage: "arrow.turn.down.right")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(!controller.isReady)
            }
            Spacer(minLength: 0)
            Text("Now at \(MediaTimeFormatter.mmss(controller.currentTime))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            RecordingSpeedMenu(rates: controller.availableRates, currentRate: controller.currentRate,
                               isEnabled: controller.isReady) { rate in
                controller.setRate(rate)
            }
            Spacer(minLength: 0)
            Toggle("Loop my marks", isOn: $loopEnabled)
                .font(.subheadline)
                .disabled(marks.loopRange == nil)
                .fixedSize()
        }
    }

    private func errorBlock(_ code: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(YouTubeErrorText.message(code: code), systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Theme.garnet)
            if let url = openInYouTubeURL {
                Link(destination: url) {
                    Label("Open in YouTube", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Actions

    private func jump(to seconds: Double?) {
        guard let seconds = seconds else { return }
        controller.seek(to: seconds)
        if controller.hasPlayed {
            controller.play()
        }
    }

    private func enforceLoop(_ time: Double) {
        guard loopEnabled, let range = marks.loopRange else { return }
        if time >= range.end {
            controller.seek(to: range.start)
        }
    }
}
