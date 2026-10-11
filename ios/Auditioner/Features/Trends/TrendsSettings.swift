import Foundation

/// UserDefaults keys for "Popular with other players" (PLAN D6). Sharing is **off** until the player
/// turns it on, and turning it on first asks whether they are 18 or older.
enum TrendsSettings {
    /// Bool, default false: the player shares which catalogue excerpts they practised each week.
    static let sharingKey: String = "trends.sharing"
    /// Bool, default false: the player confirmed they are 18 or older (asked when turning sharing on).
    static let adultConfirmedKey: String = "trends.adultConfirmed"

    static func isSharingOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: sharingKey)
    }

    static func isAdultConfirmed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: adultConfirmedKey)
    }

    /// Popularity lists are shown only to players who share, which needs the 18+ confirmation
    /// (D6: hidden for under-18s). Open question for Milai: show them to everyone who confirms 18+?
    static func showsPopularity(sharing: Bool, adultConfirmed: Bool) -> Bool {
        sharing && adultConfirmed
    }

    static func showsPopularity(_ defaults: UserDefaults = .standard) -> Bool {
        showsPopularity(sharing: isSharingOn(defaults), adultConfirmed: isAdultConfirmed(defaults))
    }
}
