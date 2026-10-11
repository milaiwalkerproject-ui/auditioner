import SwiftUI

/// Settings → About → "Find an orchestra near you": opens Tutti, the sister app for finding orchestras
/// and their auditions (PLAN U1), in the in-app Safari view. Shows nothing while
/// `TuttiLink.findOrchestraURL` is `nil` (set it in Core/Routing/DeepLink.swift once Milai confirms the address).
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
