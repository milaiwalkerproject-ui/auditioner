import SwiftUI

/// Settings → About → "Find an orchestra near you": opens Tutti, the sister app for finding orchestras
/// and their auditions (PLAN U1b: https://tutti-orchestra.com), in the in-app Safari view. The address
/// lives in `TuttiLink.findOrchestraURL` (Core/Routing/DeepLink.swift); the row shows nothing if it is `nil`.
struct TuttiLinkRow: View {
    @State private var safariItem: SafariLinkItem? = nil

    var body: some View {
        if let url = TuttiLink.findOrchestraURL {
            Button {
                safariItem = SafariLinkItem.make(url)
            } label: {
                Label("Find an orchestra near you", systemImage: "building.columns")
            }
            .sheet(item: $safariItem) { item in
                ExcerptSafariView(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }
}
