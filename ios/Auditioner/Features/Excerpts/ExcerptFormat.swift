import Foundation

/// Pure text helpers for the excerpt pages. Nothing here knows any musical fact:
/// it only formats values that come out of the catalogue.
enum ExcerptFormat {
    // MARK: Composer

    /// Surname used for grouping and headings: the last word of the composer's name
    /// ("Ludwig van Beethoven" → "Beethoven"). Same rule as `Excerpt.workHeading`.
    static func surname(_ composer: String) -> String {
        let parts: [String] = composer.split(separator: " ").map { String($0) }
        return parts.last ?? composer
    }

    /// Key for alphabetical sorting that ignores case and accents.
    static func sortKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
    }

    // MARK: Techniques

    /// "sustained-legato" → "Sustained legato".
    static func humanizeTechnique(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        let words: [String] = normalized.split(separator: "-").map { String($0) }.filter { !$0.isEmpty }
        guard let first = words.first else { return raw }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        let rest: [String] = Array(words.dropFirst())
        return ([head] + rest).joined(separator: " ")
    }

    // MARK: Difficulty

    /// "Level 3 of 5" — shown only for approved difficulty values.
    static func difficultyLabel(_ value: Int) -> String {
        String(localized: "Level \(value) of 5")
    }

    // MARK: Dates

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Shows a catalogue date ("2026-10-10") the way the user's locale writes dates.
    /// Falls back to the raw text when it cannot be parsed.
    static func displayDate(_ iso: String) -> String {
        let day = String(iso.prefix(10))
        if let date = isoDayFormatter.date(from: day) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return iso
    }

    // MARK: Copyright

    enum CopyrightRegion: String, CaseIterable {
        case us = "US"
        case eu = "EU"
        case ca = "CA"
    }

    /// Plain-words line for a verified copyright status in one region.
    static func copyrightLine(_ value: CopyrightValue, region: CopyrightRegion) -> String {
        switch (value, region) {
        case (.publicDomain, .us): return String(localized: "Public domain in the US")
        case (.publicDomain, .eu): return String(localized: "Public domain in the EU")
        case (.publicDomain, .ca): return String(localized: "Public domain in Canada")
        case (.protected, .us): return String(localized: "Protected in the US")
        case (.protected, .eu): return String(localized: "Protected in the EU")
        case (.protected, .ca): return String(localized: "Protected in Canada")
        }
    }

    // MARK: Links

    /// "https://www.aso.org/x.pdf" → "aso.org": a short label for a source link.
    static func hostLabel(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        if host.lowercased().hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// "0.5×", "1×", "1.25×".
    static func rateLabel(_ rate: Double) -> String {
        String(format: "%g×", rate)
    }

    /// Movement line for the header, e.g. "Mvt. II · Andante con moto".
    static func movementLine(_ movement: Movement?) -> String? {
        guard let movement = movement else { return nil }
        let number: String? = movement.number.map { "Mvt. \(Excerpt.roman($0))" }
        let title: String? = movement.title.flatMap { $0.isEmpty ? nil : $0 }
        let parts: [String] = [number, title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "<orchestra> <year>: <text>" for a location variant seen on a real list.
    static func variantLine(_ variant: LocationVariant) -> String {
        let year: String? = variant.year.map { String($0) }
        let who: [String] = [variant.orchestra, year].compactMap { $0 }.filter { !$0.isEmpty }
        if who.isEmpty { return variant.location.text }
        return who.joined(separator: " ") + ": " + variant.location.text
    }
}

/// Note symbols for tempo ranges ("♩ = 88–96").
enum TempoSymbols {
    /// Symbol for a catalogue `beatUnit` ("quarter", "dotted-half", ...). Dotted units get a trailing dot.
    static func symbol(forBeatUnit unit: String) -> String {
        let key = unit.lowercased().replacingOccurrences(of: "_", with: "-")
        let dotted = key.hasPrefix("dotted-")
        let base = dotted ? String(key.dropFirst("dotted-".count)) : key
        let glyph: String
        switch base {
        case "whole": glyph = "\u{1D15D}"
        case "half": glyph = "\u{1D15E}"
        case "quarter": glyph = "\u{2669}"
        case "eighth": glyph = "\u{266A}"
        case "sixteenth", "16th": glyph = "\u{1D161}"
        default: return ExcerptFormat.humanizeTechnique(unit)
        }
        return dotted ? glyph + "." : glyph
    }

    /// "88" for whole numbers, "88.5" otherwise.
    static func bpmText(_ bpm: Double) -> String {
        if bpm.rounded() == bpm {
            return String(Int(bpm))
        }
        return String(format: "%.1f", bpm)
    }

    /// "♩ = 88–96", or "♩ = 88" when the range is a single value.
    static func text(for range: TempoRange) -> String {
        let symbol = symbol(forBeatUnit: range.beatUnit)
        let low = min(range.bpmMin, range.bpmMax)
        let high = max(range.bpmMin, range.bpmMax)
        if low == high {
            return "\(symbol) = \(bpmText(low))"
        }
        return "\(symbol) = \(bpmText(low))\u{2013}\(bpmText(high))"
    }
}

/// Outbound links built from catalogue text. Only services the plan names (YouTube, Apple Music, IMSLP).
enum ExcerptLinks {
    private static func url(base: String, queryName: String, value: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = [URLQueryItem(name: queryName, value: value)]
        return components.url
    }

    /// Words a musician would type to find this excerpt: surname, work, excerpt title, instrument.
    static func searchTerms(for excerpt: Excerpt) -> String {
        let parts: [String] = [ExcerptFormat.surname(excerpt.composer), excerpt.work, excerpt.title,
                               excerpt.instrument.displayName, "excerpt"]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func youtubeSearchURL(for excerpt: Excerpt) -> URL? {
        url(base: "https://www.youtube.com/results", queryName: "search_query", value: searchTerms(for: excerpt))
    }

    static func appleMusicSearchURL(for excerpt: Excerpt) -> URL? {
        let parts: [String] = [excerpt.composer, excerpt.work, excerpt.movement?.title ?? ""]
        let term = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return url(base: "https://music.apple.com/search", queryName: "term", value: term)
    }

    /// The work's IMSLP page when the catalogue knows it, otherwise an IMSLP search for "composer work".
    static func imslpURL(for excerpt: Excerpt) -> URL? {
        if let page = excerpt.workIds?.imslpURL { return page }
        return imslpSearchURL(composer: excerpt.composer, work: excerpt.work)
    }

    static func imslpSearchURL(composer: String, work: String) -> URL? {
        url(base: "https://imslp.org/wiki/Special:Search", queryName: "search", value: "\(composer) \(work)")
    }

    /// https://www.youtube.com/watch?v=<id>&t=<start>s — the fallback when the embedded player cannot play.
    static func openInYouTubeURL(videoId: String, startSeconds: Int?) -> URL? {
        guard var components = URLComponents(string: "https://www.youtube.com/watch") else { return nil }
        var items: [URLQueryItem] = [URLQueryItem(name: "v", value: videoId)]
        if let start = startSeconds, start > 0 {
            items.append(URLQueryItem(name: "t", value: "\(start)s"))
        }
        components.queryItems = items
        return components.url
    }
}
