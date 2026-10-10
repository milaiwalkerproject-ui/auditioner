import SwiftUI

/// CONTRACT (owner: practice agent): notation + reference playback for a score.
struct PracticePlayerView: View {
    let document: ScoreDocument
    var body: some View { Text(document.title) }
}
