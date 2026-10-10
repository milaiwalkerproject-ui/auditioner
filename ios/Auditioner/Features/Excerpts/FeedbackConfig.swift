import Foundation

/// Where "Report an error" emails go. Nothing is sent from the app itself: the button
/// only opens the Mail app with a prefilled message.
enum FeedbackConfig {
    // TODO(Milai): replace this placeholder with the real feedback address before the first
    // TestFlight build. While it still ends in "example.com" the "Report an error" button is hidden.
    static let address: String = "auditioner.feedback@example.com"

    /// True once a real address has been set.
    static func isConfigured(_ address: String = FeedbackConfig.address) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else { return false }
        return !trimmed.hasSuffix("example.com")
    }

    /// mailto: link for one prose block of one excerpt. `nil` while the address is not configured.
    static func reportURL(excerptId: String, section: String, origin: ContentOrigin,
                          address: String = FeedbackConfig.address) -> URL? {
        guard isConfigured(address) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = "Auditioner: error in \(excerptId) (\(section))"
        let body = "Excerpt: \(excerptId)\nSection: \(section)\nText origin: \(origin.rawValue)\n\nWhat is wrong:\n"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}
