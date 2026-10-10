import SwiftUI

/// CONTRACT (owner: editor builder): correct the notes the server read from a scan.
/// Presented from the practice player ("Fix notes"). Calls `onSaved` with the corrected document
/// (origin `.edited`, already saved as a ScoreRecord) so the player can reload it.
struct ScoreEditorView: View {
    let document: ScoreDocument
    var onSaved: (ScoreDocument) -> Void

    var body: some View {
        Text(document.title)
    }
}
