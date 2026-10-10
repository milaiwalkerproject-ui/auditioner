import SwiftUI

/// CONTRACT (owner: media agent): plays one recording cued to the excerpt.
struct RecordingPlayerView: View {
    let recording: Recording
    let excerpt: Excerpt
    var body: some View { Text(recording.title) }
}
