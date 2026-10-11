import Foundation
import Combine

/// Loads the bundled excerpt catalogue (Resources/Catalog/catalog-<instrument>.json).
/// Only `published` excerpts are shown unless reviewer mode is on.
final class CatalogStore: ObservableObject {
    @Published private(set) var excerpts: [Excerpt] = []
    @Published private(set) var licenseNotes: [String] = []
    @Published private(set) var loadErrors: [String] = []

    init(bundle: Bundle = .main) {
        load(from: bundle)
    }

    /// For tests and previews.
    init(excerpts: [Excerpt]) {
        self.excerpts = excerpts
    }

    func load(from bundle: Bundle) {
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("catalog-") }
        var all: [Excerpt] = []
        var notes: [String] = []
        var errors: [String] = []
        let decoder = JSONDecoder()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                let file = try decoder.decode(CatalogFile.self, from: data)
                all.append(contentsOf: file.excerpts)
                notes.append(contentsOf: file.licenseNotes ?? [])
            } catch {
                errors.append("\(url.lastPathComponent): \(error)")
            }
        }
        excerpts = all
        licenseNotes = notes
        loadErrors = errors
    }

    func excerpts(for instrument: Instrument, includeDrafts: Bool) -> [Excerpt] {
        excerpts.filter { $0.instrument == instrument && (includeDrafts || $0.listingStatus == .published) }
    }

    func excerpt(id: String) -> Excerpt? {
        excerpts.first { $0.id == id }
    }

    var instrumentsWithContent: [Instrument] {
        Instrument.allCases.filter { inst in excerpts.contains { $0.instrument == inst } }
    }

    /// Simple text search over composer, work, title and catalogue number.
    func search(_ query: String, instrument: Instrument?, includeDrafts: Bool) -> [Excerpt] {
        let pool = excerpts.filter {
            (instrument == nil || $0.instrument == instrument) && (includeDrafts || $0.listingStatus == .published)
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return pool }
        let tokens = CatalogMatcher.tokens(q)
        return pool
            .map { ($0, CatalogMatcher.score(tokens: tokens, excerpt: $0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

/// Fuzzy matching of free text (typed, or OCR'd from a scan) against catalogue entries.
enum CatalogMatcher {
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    static func haystack(_ e: Excerpt) -> [String] {
        let parts = [e.composer, e.work, e.title, e.catalogueNumber ?? "", e.movement?.title ?? "", e.part ?? ""]
        return tokens(parts.joined(separator: " "))
    }

    /// Fraction of query tokens found in the excerpt's text (prefix match), weighted toward composer/work.
    static func score(tokens query: [String], excerpt: Excerpt) -> Double {
        guard !query.isEmpty else { return 0 }
        let hay = haystack(excerpt)
        let composerTokens = Set(tokens(excerpt.composer))
        var score = 0.0
        for q in query {
            if hay.contains(where: { $0.hasPrefix(q) || q.hasPrefix($0) && $0.count >= 4 }) {
                score += composerTokens.contains(where: { $0.hasPrefix(q) }) ? 1.5 : 1.0
            }
        }
        return score / Double(query.count)
    }

    /// Rank catalogue entries against OCR lines from a scanned page.
    static func rank(ocrText: String, in pool: [Excerpt], limit: Int = 5) -> [(excerpt: Excerpt, score: Double)] {
        let t = tokens(ocrText)
        guard !t.isEmpty else { return [] }
        return pool
            .map { e -> (excerpt: Excerpt, score: Double) in
                let hay = Set(haystack(e))
                let hits = hay.filter { h in t.contains(where: { $0 == h || ($0.count >= 5 && h.hasPrefix($0)) }) }
                return (e, Double(hits.count) / Double(max(hay.count, 1)))
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
