import SwiftUI

/// Plays one recording cued to the excerpt. One player per screen; the caller gives it a
/// `.id(recording.id)` when it swaps recordings so the player is rebuilt.
struct RecordingPlayerView: View {
    let recording: Recording
    let excerpt: Excerpt

    var body: some View {
        switch recording.provider {
        case .youtube:
            if let videoId = recording.youtubeId, !videoId.isEmpty {
                YouTubeRecordingPlayer(recording: recording, excerpt: excerpt, videoId: videoId)
            } else {
                RecordingUnavailableView(recording: recording,
                                         message: String(localized: "This recording has no YouTube video id yet."))
            }
        case .appleMusic:
            AppleMusicRecordingPlayer(recording: recording, excerpt: excerpt)
        case .hosted:
            if let urlString = recording.url, let url = URL(string: urlString) {
                HostedRecordingPlayer(recording: recording, excerpt: excerpt, url: url)
            } else {
                RecordingUnavailableView(recording: recording,
                                         message: String(localized: "This recording's file isn't available yet."))
            }
        case .link:
            LinkRecordingView(recording: recording)
        }
    }
}
