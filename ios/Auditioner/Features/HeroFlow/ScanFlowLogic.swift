import Foundation

/// Which way the flow goes once the excerpt (if any) is known.
enum ScanReferencePath: Equatable {
    /// The catalogue ships a checked MusicXML file for this excerpt: play it, nothing leaves the device.
    case curated(fileName: String)
    /// Notes would have to be read by the server, but no server address is set in Settings.
    case serverNotConfigured
    /// Send the cropped picture to the Auditioner server to read the notes.
    case recognizeOnServer
}

/// Pure decisions for the scan → reference-audio flow. No UI, no I/O, so it can be unit-tested.
struct ScanFlowLogic {

    // MARK: Which path

    /// Decides what happens after identification.
    /// - Parameters:
    ///   - excerpt: the identified excerpt, or `nil` when the user said "It's not in the list".
    ///   - serverConfigured: `AppSettings.serverBaseURL != nil`.
    static func referencePath(excerpt: Excerpt?, serverConfigured: Bool) -> ScanReferencePath {
        if let fileName = excerpt?.referenceMusicXML?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileName.isEmpty {
            return .curated(fileName: fileName)
        }
        return serverPath(serverConfigured: serverConfigured)
    }

    /// The path when there is no curated file (or the curated file turned out to be missing from the bundle).
    static func serverPath(serverConfigured: Bool) -> ScanReferencePath {
        serverConfigured ? .recognizeOnServer : .serverNotConfigured
    }

    /// Identification is skipped when the flow started from an excerpt page ("Scan my part").
    static func needsIdentification(contextExcerpt: Excerpt?) -> Bool {
        contextExcerpt == nil
    }

    /// The consent screen is shown once, right before the first upload (PLAN R5), never for curated files.
    static func needsConsent(hasAccepted: Bool, path: ScanReferencePath) -> Bool {
        path == .recognizeOnServer && !hasAccepted
    }

    /// A page picker is only worth showing when there is something to pick.
    static func needsPagePicker(pageCount: Int) -> Bool {
        pageCount > 1
    }

    // MARK: Transposition

    /// Semitones added to the written pitch when no catalogue value is known.
    ///
    /// Written pitch is what the server's note reading returns. Only octave transpositions are safe to
    /// assume from the instrument alone: double bass and contrabassoon sound an octave lower than written,
    /// piccolo an octave higher. For clarinet, horn, trumpet, English horn, E♭ and bass clarinet the
    /// printed key ("in B♭", "in F", "in A"…) must drive the transposition, not the instrument profile
    /// (PLAN R4) — M2 adds reading that key from the part. Until then these return 0 (written pitch).
    static func defaultTransposition(for instrument: Instrument) -> Int {
        switch instrument {
        case .doubleBass, .contrabassoon:
            return -12
        case .piccolo:
            return 12
        default:
            return 0
        }
    }

    /// The catalogue's checked value wins; otherwise the octave default for the instrument.
    static func transposition(excerpt: Excerpt?, fallbackInstrument: Instrument) -> Int {
        if let known = excerpt?.soundingTransposition {
            return known
        }
        return defaultTransposition(for: excerpt?.instrument ?? fallbackInstrument)
    }

    /// Instrument sent to the server: the excerpt's when known, else the player's own.
    static func omrInstrument(excerpt: Excerpt?, settingsInstrument: Instrument) -> Instrument {
        excerpt?.instrument ?? settingsInstrument
    }

    /// Meter hint for the server: only a verified catalogue value (honesty contract), never a guess.
    static func meterHint(excerpt: Excerpt?) -> String? {
        excerpt?.meter?.verifiedValue
    }

    // MARK: Titles

    /// Title of the saved reference: "Strauss · Don Juan — Mvt. II · Opening", or "Scanned part <date>".
    static func scoreTitle(excerpt: Excerpt?, date: Date, locale: Locale = .current) -> String {
        if let excerpt {
            return "\(excerpt.workHeading) — \(excerpt.subtitle)"
        }
        return String(localized: "Scanned part \(shortDate(date, locale: locale))")
    }

    /// Title of the copy kept in My parts.
    static func libraryTitle(for source: ScanSource, date: Date, locale: Locale = .current) -> String {
        switch source {
        case .camera:
            return String(localized: "Scan \(shortDate(date, locale: locale))")
        case .photos:
            return String(localized: "Photo \(shortDate(date, locale: locale))")
        case .files, .libraryItem:
            // Files keep the name they came with (LibraryStore derives it); library items already exist.
            return String(localized: "Part \(shortDate(date, locale: locale))")
        }
    }

    static func shortDate(_ date: Date, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                     calendar: Calendar.current, timeZone: TimeZone.current)
        return date.formatted(style)
    }

    // MARK: Identification

    /// OCR lines joined for matching.
    static func ocrText(lines: [String]) -> String {
        lines.joined(separator: " ")
    }

    /// Best catalogue matches for the recognised text, best first.
    static func candidates(ocrLines: [String], pool: [Excerpt], limit: Int = 5) -> [Excerpt] {
        let text = ocrText(lines: ocrLines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return CatalogMatcher.rank(ocrText: text, in: pool, limit: limit).map { $0.excerpt }
    }

    // MARK: Version string

    /// "0.1.0 (1)" for the About row.
    static func versionString(short: String?, build: String?) -> String {
        let shortClean = (short ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let buildClean = (build ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (shortClean.isEmpty, buildClean.isEmpty) {
        case (true, true): return "—"
        case (false, true): return shortClean
        case (true, false): return "(\(buildClean))"
        case (false, false): return "\(shortClean) (\(buildClean))"
        }
    }
}
