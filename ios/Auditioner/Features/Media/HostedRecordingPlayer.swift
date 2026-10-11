import SwiftUI
import SwiftData
import AVFoundation
import AVKit
import Combine

/// AVPlayer for the free-licence recordings we host: slow-down (pitch kept), marks, A–B loop.
final class HostedPlayerController: ObservableObject {
    let player: AVPlayer

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var rate: Double = 1
    @Published private(set) var isPlaying: Bool = false

    var loopRange: (start: Double, end: Double)? = nil
    var loopEnabled: Bool = false

    private var timeObserver: Any? = nil
    private var statusObservation: NSKeyValueObservation? = nil

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            self.currentTime = max(0, seconds)
            if self.loopEnabled, let range = self.loopRange, seconds >= range.end {
                self.seek(to: range.start)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            DispatchQueue.main.async {
                self?.isPlaying = playing
            }
        }
    }

    deinit {
        if let token = timeObserver {
            player.removeTimeObserver(token)
        }
        statusObservation?.invalidate()
        player.pause()
    }

    func play() {
        player.play()
        player.rate = Float(rate)
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        if player.timeControlStatus == .playing {
            player.rate = Float(newRate)
        }
    }
}

struct HostedRecordingPlayer: View {
    static let rates: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    let recording: Recording
    let excerpt: Excerpt
    let url: URL

    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller: HostedPlayerController
    @StateObject private var marks: RecordingMarks
    @State private var loopEnabled: Bool = false

    init(recording: Recording, excerpt: Excerpt, url: URL) {
        self.recording = recording
        self.excerpt = excerpt
        self.url = url
        _controller = StateObject(wrappedValue: HostedPlayerController(url: url))
        _marks = StateObject(wrappedValue: RecordingMarks(excerpt: excerpt, recording: recording))
    }

    private var verifiedStart: Double? {
        recording.start?.verifiedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlayer(player: controller.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200)
                .background(Color.black)
            RecordingStartStatusLine(verifiedStart: verifiedStart)
            transportRow
            RecordingMarkControls(
                marks: marks,
                onMarkStart: { marks.setStart(controller.currentTime, in: modelContext) },
                onMarkEnd: { marks.setEnd(controller.currentTime, in: modelContext) },
                onJumpToStart: { jump(to: marks.start) }
            )
            controlsRow
            if let license = recording.license, !license.isEmpty {
                Text("Licence: \(license)")
                    .font(.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .onAppear {
            marks.load(from: modelContext)
            syncLoop()
        }
        .onDisappear {
            controller.pause()
        }
        .onChange(of: loopEnabled) { _, _ in
            syncLoop()
        }
        .onChange(of: marks.start) { _, _ in
            syncLoop()
        }
        .onChange(of: marks.end) { _, _ in
            syncLoop()
        }
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                if controller.isPlaying {
                    controller.pause()
                } else {
                    controller.play()
                }
            } label: {
                Label(controller.isPlaying ? String(localized: "Pause") : String(localized: "Play"), systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if verifiedStart != nil {
                Button {
                    jump(to: verifiedStart)
                } label: {
                    Label("Jump to start", systemImage: "arrow.turn.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Text(MediaTimeFormatter.mmss(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            RecordingSpeedMenu(rates: HostedRecordingPlayer.rates, currentRate: controller.rate, isEnabled: true) { rate in
                controller.setRate(rate)
            }
            Spacer(minLength: 0)
            Toggle("Loop my marks", isOn: $loopEnabled)
                .font(.subheadline)
                .disabled(marks.loopRange == nil)
                .fixedSize()
        }
    }

    private func jump(to seconds: Double?) {
        guard let seconds = seconds else { return }
        controller.seek(to: seconds)
    }

    private func syncLoop() {
        controller.loopRange = marks.loopRange
        controller.loopEnabled = loopEnabled && marks.loopRange != nil
    }
}
