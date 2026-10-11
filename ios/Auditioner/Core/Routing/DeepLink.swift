import Foundation

// Links into Auditioner (PLAN U1, Tutti link-in). Formats and examples: docs/TUTTI.md.
//
//   auditioner://excerpt/<excerptId>
//   auditioner://audition/new?orchestra=…&position=…&instrument=<Instrument raw id>
//                              &deadline=YYYY-MM-DD&auditionDate=YYYY-MM-DD&url=<https only>
//
// Parsing is pure and unit-tested (DeepLinkTests). Nothing a link carries is saved: the excerpt link
// only opens a page, the audition link only fills in the "New audition" form.

/// Values a link may put into the "New audition" form. The player still has to tap Save.
struct AuditionPrefill: Equatable {
    var orchestra: String = ""
    var position: String = ""
    /// `nil` → the form uses the player's own instrument from Settings.
    var instrument: Instrument? = nil
    var deadline: Date? = nil
    var auditionDate: Date? = nil
    /// Address of the official page; https only, already checked.
    var sourceURL: String? = nil

    var isEmpty: Bool {
        orchestra.isEmpty && position.isEmpty && instrument == nil && deadline == nil && auditionDate == nil && sourceURL == nil
    }
}

/// A link another app opened Auditioner with.
enum DeepLink: Equatable {
    case excerpt(id: String)
    case newAudition(AuditionPrefill)

    /// Registered in ios/Auditioner-Info.plist (CFBundleURLTypes).
    static let scheme: String = "auditioner"
    /// Longest value accepted for any part of a link; the rest is cut off.
    static let maxValueLength: Int = 200

    /// `nil` for anything that isn't one of our links. Unknown or empty query values are simply ignored,
    /// so `auditioner://audition/new` on its own opens an empty form.
    static func parse(_ url: URL, calendar: Calendar = .current) -> DeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == DeepLink.scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // "auditioner://excerpt/x" puts "excerpt" in the host; "auditioner:///excerpt/x" puts it in the path.
        var segments: [String] = []
        if let host = components.host, !host.isEmpty {
            segments.append(host)
        }
        let pathPieces: [String] = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
        segments.append(contentsOf: pathPieces)

        guard let kind = segments.first?.lowercased() else { return nil }
        let rest: [String] = Array(segments.dropFirst())
        switch kind {
        case "excerpt":
            guard rest.count == 1, let id = cleaned(rest[0]) else { return nil }
            return .excerpt(id: id)
        case "audition":
            guard rest.count == 1, rest[0].lowercased() == "new" else { return nil }
            return .newAudition(prefill(from: components.queryItems ?? [], calendar: calendar))
        default:
            return nil
        }
    }

    // MARK: Pieces (internal so the tests can check them one by one)

    /// Query → prefill. The first valid value of each parameter wins; invalid ones are dropped.
    static func prefill(from items: [URLQueryItem], calendar: Calendar) -> AuditionPrefill {
        var prefill = AuditionPrefill()
        for item in items {
            guard let value = cleaned(item.value) else { continue }
            switch item.name.lowercased() {
            case "orchestra" where prefill.orchestra.isEmpty:
                prefill.orchestra = value
            case "position" where prefill.position.isEmpty:
                prefill.position = value
            case "instrument" where prefill.instrument == nil:
                prefill.instrument = Instrument(rawValue: value.lowercased())
            case "deadline" where prefill.deadline == nil:
                prefill.deadline = day(value, calendar: calendar)
            case "auditiondate" where prefill.auditionDate == nil:
                prefill.auditionDate = day(value, calendar: calendar)
            case "url" where prefill.sourceURL == nil:
                prefill.sourceURL = httpsAddress(value)
            default:
                break
            }
        }
        return prefill
    }

    /// Trimmed, line breaks turned into spaces, cut to `maxValueLength`; `nil` when nothing is left.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let oneLine: String = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed: String = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut: String = String(trimmed.prefix(maxValueLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    /// Exactly "YYYY-MM-DD" and a real calendar day (no 2026-02-30); noon of that day, or `nil`.
    static func day(_ text: String, calendar: Calendar) -> Date? {
        guard looksLikeISODay(text) else { return nil }
        return AuditionDates.parseDay(text, calendar: calendar)
    }

    /// Ten characters: four digits, "-", two digits, "-", two digits. ASCII digits only.
    static func looksLikeISODay(_ text: String) -> Bool {
        let scalars: [Unicode.Scalar] = Array(text.unicodeScalars)
        guard scalars.count == 10 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 {
                if scalar != "-" { return false }
            } else if scalar.value < 48 || scalar.value > 57 {
                return false
            }
        }
        return true
    }

    /// The address itself when it is https with a host; anything else (http, javascript:, file:) is `nil`.
    static func httpsAddress(_ text: String) -> String? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return text
    }
}

/// What the app does with a parsed link.
enum DeepLinkRouting {
    enum Outcome: Equatable {
        case followed
        /// The id isn't in the catalogue on this device; the caller shows "That excerpt isn't in the catalogue yet."
        case excerptMissing
    }

    @discardableResult
    static func follow(_ link: DeepLink, router: AppRouter, catalog: CatalogStore) -> Outcome {
        switch link {
        case .excerpt(let id):
            router.selectedTab = .excerpts
            guard catalog.excerpt(id: id) != nil else { return .excerptMissing }
            router.openedExcerptId = id
            return .followed
        case .newAudition(let prefill):
            router.selectedTab = .auditions
            router.auditionPrefill = prefill
            return .followed
        }
    }
}

/// Links out to Tutti, the sister app that helps people find an orchestra (PLAN U1).
enum TuttiLink {
    /// "Find an orchestra near you" in Settings → About. The row stays hidden while this is `nil`.
    /// TO SET: once Milai confirms Tutti's web address, replace `nil` with e.g.
    /// `URL(string: "https://<tutti's address>")` — https only, nothing else to change.
    static let findOrchestraURL: URL? = nil
}
