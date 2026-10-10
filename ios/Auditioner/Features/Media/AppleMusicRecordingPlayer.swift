import SwiftUI
import MusicKit

/// Looks a song up by ISRC and plays it with the system music player (subscribers), cued to
/// the verified start. Everyone else gets "Open in Apple Music". Never behind a paywall of ours.
final class AppleMusicPlayerModel: ObservableObject {
    enum Phase {
        case idle
        case loading
        case ready(Song)
        case openOnly(Song)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var isPlaying: Bool = false
    private var hasCuedStart: Bool = false

    @MainActor
    func load(isrc: String, startSeconds: Double?) async {
        phase = .loading
        hasCuedStart = false
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            phase = .failed(String(localized: "Auditioner needs permission to use Apple Music. You can allow it in the Settings app."))
            return
        }
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
            request.limit = 1
            let response = try await request.response()
            guard let song = response.items.first else {
                phase = .failed(String(localized: "This recording isn't in the Apple Music catalogue for your country."))
                return
            }
            let subscription = try await MusicSubscription.current
            if subscription.canPlayCatalogContent {
                let player = ApplicationMusicPlayer.shared
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                try await player.prepareToPlay()
                if let start = startSeconds, start > 0 {
                    player.playbackTime = start
                    hasCuedStart = true
                }
                phase = .ready(song)
            } else {
                phase = .openOnly(song)
            }
        } catch {
            phase = .failed(String(localized: "Apple Music couldn't load this recording. \(error.localizedDescription)"))
        }
    }

    @MainActor
    func play(startSeconds: Double?) async {
        let player = ApplicationMusicPlayer.shared
        if !hasCuedStart, let start = startSeconds, start > 0 {
            player.playbackTime = start
            hasCuedStart = true
        }
        do {
            try await player.play()
            isPlaying = true
        } catch {
            isPlaying = false
            phase = .failed(String(localized: "Apple Music couldn't start playing. \(error.localizedDescription)"))
        }
    }

    func pause() {
        ApplicationMusicPlayer.shared.pause()
        isPlaying = false
    }

    func jump(to seconds: Double) {
        ApplicationMusicPlayer.shared.playbackTime = max(0, seconds)
    }
}

struct AppleMusicRecordingPlayer: View {
    let recording: Recording
    let excerpt: Excerpt

    @StateObject private var model = AppleMusicPlayerModel()

    private var verifiedStart: Double? {
        recording.start?.verifiedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recording.title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            if let performer = recording.performer, !performer.isEmpty {
                Text(performer)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            RecordingStartStatusLine(verifiedStart: verifiedStart)
            content
        }
        .task {
            await load()
        }
        .onDisappear {
            model.pause()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking up this recording in Apple Music…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        case .ready(let song):
            readyControls(song)
        case .openOnly(let song):
            VStack(alignment: .leading, spacing: 8) {
                Text("Playing inside the app needs an Apple Music subscription.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                openLink(song.url, prominent: true)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.garnet)
                Button("Try again") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                if let urlString = recording.url, let url = URL(string: urlString) {
                    openLink(url, prominent: false)
                }
            }
        }
    }

    private func readyControls(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(song.title) — \(song.artistName)")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            HStack(spacing: 10) {
                Button {
                    if model.isPlaying {
                        model.pause()
                    } else {
                        Task { await model.play(startSeconds: verifiedStart) }
                    }
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if let start = verifiedStart {
                    Button {
                        model.jump(to: start)
                    } label: {
                        Label("Jump to start", systemImage: "arrow.turn.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            openLink(song.url, prominent: false)
        }
    }

    @ViewBuilder
    private func openLink(_ url: URL?, prominent: Bool) -> some View {
        if let url = url {
            if prominent {
                Link(destination: url) {
                    Label("Open in Apple Music", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Link("Open in Apple Music", destination: url)
                    .font(.caption)
            }
        }
    }

    @MainActor
    private func load() async {
        guard let isrc = recording.isrc, !isrc.isEmpty else {
            model.phase = .failed(String(localized: "This recording has no Apple Music identifier yet."))
            return
        }
        await model.load(isrc: isrc, startSeconds: verifiedStart)
    }
}
