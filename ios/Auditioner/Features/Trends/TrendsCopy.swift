import Foundation

/// The words of "Popular with other players", in one place (plain words for musicians, sentence case).
enum TrendsCopy {
    // MARK: Settings

    static var settingsHeader: String {
        String(localized: "Popular with other players")
    }

    static var shareToggle: String {
        String(localized: "Share what I practise")
    }

    static var whatIsSent: String {
        String(localized: "When you open the app (at most twice a day) it sends your instrument, the week, and which catalogue excerpts you practised that week. No name, recordings, notes or scans. Shown only when at least 20 players share, as tiers, never numbers. Turning this off deletes what you've shared from our server.")
    }

    static var whoSees: String {
        String(localized: "Popularity lists are shown only to players who share and have confirmed they're 18 or older.")
    }

    static var ageQuestion: String {
        String(localized: "Are you 18 or older?")
    }

    static var ageYes: String {
        String(localized: "Yes, I'm 18 or older")
    }

    static var ageNo: String {
        String(localized: "No")
    }

    static var ageNote: String {
        String(localized: "Sharing and popularity lists are for players 18 and older.")
    }

    // MARK: Browser section

    /// "Popular with cello players".
    static func sectionTitle(for instrument: Instrument) -> String {
        let words: String = LocalRecommendationEngine.instrumentWords(instrument)
        return String(localized: "Popular with \(words) players")
    }

    static var sectionFooter: String {
        String(localized: "From players who share what they practise — not what orchestras ask.")
    }

    static var notEnough: String {
        String(localized: "Not enough players share yet to show this.")
    }

    static var nothingStandsOut: String {
        String(localized: "No excerpt stands out yet.")
    }

    static var checking: String {
        String(localized: "Checking what other players practise…")
    }

    // MARK: Excerpt page

    /// "Among cello players who share what they practise" — next to the tier pill.
    static func badgeText(for instrument: Instrument) -> String {
        let words: String = LocalRecommendationEngine.instrumentWords(instrument)
        return String(localized: "Among \(words) players who share what they practise")
    }
}
