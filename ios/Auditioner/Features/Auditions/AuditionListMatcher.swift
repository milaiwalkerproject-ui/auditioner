import Foundation

/// A catalogue excerpt proposed for one line of a list, with how sure the matcher is (0…1).
struct AuditionMatchCandidate: Equatable, Identifiable {
    var excerptId: String
    var score: Double

    var id: String { excerptId }
}

/// Proposes catalogue excerpts for parsed list lines. Built on `CatalogMatcher`'s tokens, with the
/// numbers (symphony number, opus) and the movement checked on top, because "Symphony No. 2" and
/// "Symphony No. 3" share every word. The player always confirms; nothing is linked on its own.
enum AuditionListMatcher {
    /// At or above this the review screen pre-ticks the link (still shown, still editable).
    static let strongThreshold: Double = 0.9
    /// Candidates this close to the best one are a tie: none of them is pre-ticked.
    static let tieGap: Double = 0.05
    static let tieCap: Double = 0.89
    /// Below this a candidate isn't worth showing.
    static let floor: Double = 0.3

    /// Words that don't tell works apart.
    private static let stopWords: Set<String> = [
        "no", "nr", "in", "op", "major", "minor", "the", "of", "and", "for", "flat", "sharp", "dur", "moll",
        "from", "to", "with", "mvt", "movement", "mm", "bars", "bar", "measures", "measure", "excerpt", "excerpts",
        "part", "parts", "orchestral", "orchestra", "solo", "passage", "passages", "section", "entry", "after",
        "around", "theme", "opening", "beginning", "end", "ending", "music", "incidental", "cello", "cellos",
        "violoncello", "violin", "viola", "bass", "horn", "trumpet", "trombone", "tuba", "flute", "oboe", "clarinet",
        "bassoon", "timpani", "percussion", "harp", "piano",
    ]

    // MARK: Candidates

    static func candidates(for item: ParsedListItem, in pool: [Excerpt], limit: Int = 3) -> [AuditionMatchCandidate] {
        var scored: [AuditionMatchCandidate] = []
        for excerpt in pool {
            let value: Double = score(item: item, excerpt: excerpt)
            if value >= floor {
                scored.append(AuditionMatchCandidate(excerptId: excerpt.id, score: value))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.excerptId < b.excerptId
        }
        var top: [AuditionMatchCandidate] = Array(scored.prefix(max(0, limit)))
        if top.count >= 2 {
            let best: Double = top[0].score
            if best - top[1].score < tieGap {
                for index in top.indices where best - top[index].score < tieGap {
                    top[index].score = min(top[index].score, tieCap)
                }
            }
        }
        return top
    }

    /// The candidate the review screen pre-ticks, if any: a lone strong match.
    static func preselected(_ candidates: [AuditionMatchCandidate]) -> String? {
        guard let best = candidates.first, isStrong(best.score) else { return nil }
        return best.excerptId
    }

    /// Compared with a hair of tolerance so 0.45 + 0.35 + 0.1 counts as 0.9.
    static func isStrong(_ score: Double) -> Bool {
        score >= strongThreshold - 1e-9
    }

    // MARK: Score

    static func score(item: ParsedListItem, excerpt: Excerpt) -> Double {
        let query: [String] = queryTokens(for: item)
        guard !query.isEmpty else { return 0 }

        // Composer: the surname has to be there.
        let composerTokens: [String] = CatalogMatcher.tokens(excerpt.composer)
        let surname: String = composerTokens.last ?? ""
        let composerHit: Bool = !surname.isEmpty && query.contains { tokenMatches($0, surname, minimumPrefix: 4) }

        // Work: share of the work's significant words found in the line.
        let workTokens: [String] = significant(CatalogMatcher.tokens(excerpt.work))
        var workScore: Double = 0
        if !workTokens.isEmpty {
            let hits: Int = workTokens.filter { word in query.contains { tokenMatches($0, word, minimumPrefix: 3) } }.count
            workScore = Double(hits) / Double(workTokens.count)
        }

        // Title / movement title: a bonus when the line names the passage ("Scherzo", "Andante con moto").
        let titleTokens: [String] = significant(CatalogMatcher.tokens(excerpt.title + " " + (excerpt.movement?.title ?? "")))
        let titleHit: Bool = titleTokens.contains { word in query.contains { tokenMatches($0, word, minimumPrefix: 4) } }

        guard composerHit || workScore >= 0.5 else { return 0 }

        var value: Double = (composerHit ? 0.45 : 0) + 0.35 * workScore + (titleHit ? 0.1 : 0)

        // Numbers: a symphony or opus number on the line must agree with the catalogue's.
        let workNumbers: Set<Int> = numbers(in: excerpt.work)
        let excerptNumbers: Set<Int> = workNumbers.union(numbers(in: excerpt.catalogueNumber ?? ""))
        let itemNumbers: Set<Int> = numbers(in: queryText(for: item))
        if itemNumbers.isEmpty {
            value += workNumbers.isEmpty ? 0.1 : 0.05
        } else if !excerptNumbers.isDisjoint(with: itemNumbers) {
            value += 0.1
        } else if !excerptNumbers.isEmpty {
            value *= 0.35
        } else {
            value += 0.05
        }

        // Movement: both known and different is a strong sign it's another excerpt.
        if let wanted = item.movementNumber, let have = excerpt.movement?.number, wanted != have {
            value *= 0.5
        }

        return min(1, max(0, value))
    }

    // MARK: Query text

    /// Composer and work words from the line, without bar numbers and movement words.
    static func queryText(for item: ParsedListItem) -> String {
        let base: String
        if let work = item.work, !work.isEmpty {
            base = (item.composer ?? "") + " " + work
        } else {
            base = item.rawText
        }
        return AuditionListParser.textWithoutLocation(base)
    }

    static func queryTokens(for item: ParsedListItem) -> [String] {
        CatalogMatcher.tokens(queryText(for: item)).filter { !stopWords.contains($0) }
    }

    /// Tokens that are words (not numbers) and not stop words.
    static func significant(_ tokens: [String]) -> [String] {
        tokens.filter { token in
            !stopWords.contains(token) && Int(token) == nil
        }
    }

    /// Whole integers in the text ("No. 5" → 5, "Op. 67" → 67, "K. 385" → 385).
    static func numbers(in text: String) -> Set<Int> {
        var result: Set<Int> = []
        for part in text.components(separatedBy: CharacterSet.decimalDigits.inverted) where !part.isEmpty {
            if let value = Int(part), value > 0, value < 100_000 {
                result.insert(value)
            }
        }
        return result
    }

    /// Equal, or one is a prefix of the other and the shorter one is long enough to mean something.
    static func tokenMatches(_ a: String, _ b: String, minimumPrefix: Int) -> Bool {
        if a == b { return true }
        let shortest: Int = min(a.count, b.count)
        guard shortest >= minimumPrefix else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// "85%" for the review screen.
    static func percentText(_ score: Double) -> String {
        let percent: Int = Int((min(1, max(0, score)) * 100).rounded())
        return "\(percent)%"
    }
}

// MARK: - Review lines

/// One line on the "Check the list" screen: editable text, the proposed link, the player's decision.
struct AuditionReviewLine: Identifiable, Equatable {
    let id: UUID
    var include: Bool
    var text: String
    var round: String
    var category: String
    var candidates: [AuditionMatchCandidate]
    /// The excerpt the player ticked; `nil` = not linked.
    var chosenExcerptId: String?

    var parsed: ParsedListItem {
        AuditionListParser.analyzed(ParsedListItem(rawText: text, round: round, category: category))
    }
}

enum AuditionReviewLogic {
    /// Review lines for parsed items: every line included, strong lone matches pre-ticked.
    static func lines(from items: [ParsedListItem], pool: [Excerpt]) -> [AuditionReviewLine] {
        items.map { item in
            let candidates: [AuditionMatchCandidate] = AuditionListMatcher.candidates(for: item, in: pool)
            return AuditionReviewLine(id: UUID(),
                                      include: true,
                                      text: item.rawText,
                                      round: item.round,
                                      category: item.category,
                                      candidates: candidates,
                                      chosenExcerptId: AuditionListMatcher.preselected(candidates))
        }
    }

    /// Recomputes the candidates after the player edited a line's text (the chosen link is kept only if it is still proposed).
    static func rematched(_ line: AuditionReviewLine, pool: [Excerpt]) -> AuditionReviewLine {
        var result = line
        result.candidates = AuditionListMatcher.candidates(for: line.parsed, in: pool)
        if let chosen = line.chosenExcerptId, !result.candidates.contains(where: { $0.excerptId == chosen }) {
            result.chosenExcerptId = nil
        }
        return result
    }

    /// Checklist items for the lines the player kept, in order, after the existing items.
    static func items(from lines: [AuditionReviewLine], auditionId: UUID, startOrder: Int) -> [AuditionItem] {
        var result: [AuditionItem] = []
        for line in lines where line.include {
            let text: String = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let item = AuditionItem(auditionId: auditionId, order: startOrder + result.count, rawText: text)
            item.round = AuditionRounds.canonical(line.round)
            item.category = AuditionItemCategory(raw: line.category).rawValue
            item.excerptId = line.chosenExcerptId
            result.append(item)
        }
        return result
    }

    static func includedCount(_ lines: [AuditionReviewLine]) -> Int {
        lines.filter { $0.include && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}
