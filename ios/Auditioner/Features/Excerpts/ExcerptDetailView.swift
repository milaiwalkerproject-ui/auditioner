import SwiftUI

/// CONTRACT (owner: excerpts agent): one excerpt's page.
struct ExcerptDetailView: View {
    let excerpt: Excerpt
    var body: some View { Text(excerpt.title) }
}
