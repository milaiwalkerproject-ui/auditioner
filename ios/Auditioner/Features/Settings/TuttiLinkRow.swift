import SwiftUI

/// A Settings → About row that opens a page on Tutti's site inside the app (the in-app Safari view).
/// The addresses live in `TuttiLink` (Core/Routing/DeepLink.swift); the row shows nothing if its address
/// is `nil` or not http(s) (`SafariLinkItem.make` would refuse it).
struct TuttiPageRow: View {
    /// Already localized (`String(localized:)`), so the row itself never looks a key up twice.
    let title: String
    let symbol: String
    let url: URL?

    @State private var safariItem: SafariLinkItem? = nil

    var body: some View {
        if let url: URL = url {
            Button {
                safariItem = SafariLinkItem.make(url)
            } label: {
                Label(title, systemImage: symbol)
            }
            .sheet(item: $safariItem) { item in
                ExcerptSafariView(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Settings → About → "Find an orchestra near you": opens Tutti, the sister app for finding orchestras
/// and their auditions (PLAN U1b: https://tutti-orchestra.com).
struct TuttiLinkRow: View {
    var body: some View {
        TuttiPageRow(title: String(localized: "Find an orchestra near you"),
                     symbol: "building.columns",
                     url: TuttiLink.findOrchestraURL)
    }
}

/// Settings → About → "Privacy policy": the full policy on Tutti's site (PLAN U1c).
struct PrivacyPolicyLinkRow: View {
    var body: some View {
        TuttiPageRow(title: String(localized: "Privacy policy"),
                     symbol: "hand.raised",
                     url: TuttiLink.privacyPolicyURL)
    }
}

/// Settings → About → "Help and support": the support page on Tutti's site (PLAN U1c).
struct SupportLinkRow: View {
    var body: some View {
        TuttiPageRow(title: String(localized: "Help and support"),
                     symbol: "questionmark.circle",
                     url: TuttiLink.supportURL)
    }
}
