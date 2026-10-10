import SwiftUI

/// UserDefaults keys shared across features. Use with @AppStorage in views.
enum SettingsKey {
    static let instrument = "settings.instrument"          // Instrument.rawValue, default "cello"
    static let position = "settings.position"              // Position.rawValue, default "section"
    static let region = "settings.region"                  // e.g. "north-america"
    static let serverURL = "settings.serverURL"            // backend base URL, "" = not set up
    static let tuningA4 = "settings.tuningA4"              // Double, 440 or 442 etc.
    static let reviewerMode = "settings.reviewerMode"      // Bool: show drafts + unreviewed prose (Milai only)
    static let hasCompletedOnboarding = "settings.onboarded"
    static let hasAcceptedScanConsent = "settings.scanConsent"
    static let deviceId = "settings.deviceId"
}

/// Non-view access to the same settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage(SettingsKey.instrument) var instrumentRaw: String = Instrument.cello.rawValue
    @AppStorage(SettingsKey.position) var positionRaw: String = Position.section.rawValue
    @AppStorage(SettingsKey.region) var region: String = "north-america"
    @AppStorage(SettingsKey.serverURL) var serverURL: String = ""
    @AppStorage(SettingsKey.tuningA4) var tuningA4: Double = 440
    @AppStorage(SettingsKey.reviewerMode) var reviewerMode: Bool = false
    @AppStorage(SettingsKey.hasCompletedOnboarding) var hasCompletedOnboarding: Bool = false
    @AppStorage(SettingsKey.hasAcceptedScanConsent) var hasAcceptedScanConsent: Bool = false

    var instrument: Instrument {
        get { Instrument(rawValue: instrumentRaw) ?? .cello }
        set { instrumentRaw = newValue.rawValue }
    }

    var position: Position {
        get { Position(rawValue: positionRaw) ?? .section }
        set { positionRaw = newValue.rawValue }
    }

    var serverBaseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// Random per-install identifier used only for server rate limiting (never linked to a person).
    var deviceId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: SettingsKey.deviceId) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: SettingsKey.deviceId)
        return fresh
    }
}
