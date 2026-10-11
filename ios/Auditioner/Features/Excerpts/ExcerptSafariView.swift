import SwiftUI
import UIKit
import SafariServices

/// In-app Safari (SFSafariViewController) for IMSLP and other outbound pages.
/// Only http/https URLs are allowed by SFSafariViewController; callers check that.
struct ExcerptSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Theme.garnet)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // The page is fixed for the life of the sheet.
    }
}

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
struct SafariLinkItem: Identifiable {
    let id = UUID()
    let url: URL

    /// `nil` for anything SFSafariViewController would refuse (mailto:, custom schemes).
    static func make(_ url: URL?) -> SafariLinkItem? {
        guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return SafariLinkItem(url: url)
    }
}
