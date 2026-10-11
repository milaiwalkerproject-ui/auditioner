import Foundation

// Turns the lines of a repertoire list (typed, pasted or read on the device by Vision) into
// checklist items. Pure text handling: nothing leaves the device, no model is called, and the
// line's own words are kept as the item's `rawText`. Composer / work / movement / bars are
// only *hints* for matching the catalogue — they are never shown as facts.

/// A bar range as printed on the list ("mm. 12–40" → 12…40; "from bar 12" → start only).
struct BarRange: Equatable {
    var start: Int
    var end: Int?
}

/// One line of the list after parsing.
struct ParsedListItem: Equatable {
    /// The line as printed, without a leading list marker ("1.", "•").
    var rawText: String
    /// Canonical round name from the heading above it, or "" when the list has none.
    var round: String = ""
    /// `AuditionItemCategory` raw value.
    var category: String = AuditionItemCategory.excerpt.rawValue
    var composer: String? = nil
    var work: String? = nil
    var movementNumber: Int? = nil
    var bars: BarRange? = nil
}

enum AuditionListParser {

    // MARK: Entry points

    static func parse(text: String) -> [ParsedListItem] {
        let lines: [String] = text.components(separatedBy: CharacterSet.newlines)
        return parse(lines: lines)
    }

    static func parse(lines: [String]) -> [ParsedListItem] {
        var items: [ParsedListItem] = []
        var round: String = ""
        var category: AuditionItemCategory = .excerpt
        var lastWasHeading: Bool = true

        for rawLine in lines {
            let line: String = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || isNoise(line) { continue }

            if let heading = roundHeading(line) {
                round = heading
                category = .excerpt
                lastWasHeading = true
                continue
            }
            if let heading = categoryHeading(line) {
                category = heading
                lastWasHeading = true
                continue
            }

            let stripped: String = stripListMarker(line)
            let hadMarker: Bool = stripped != line

            if !hadMarker, !lastWasHeading, !items.isEmpty, isContinuation(stripped) {
                let joined: String = items[items.count - 1].rawText + " " + stripped
                items[items.count - 1] = analyzed(ParsedListItem(rawText: joined,
                                                                  round: items[items.count - 1].round,
                                                                  category: items[items.count - 1].category))
                continue
            }

            var item = ParsedListItem(rawText: stripped, round: round, category: category.rawValue)
            if isSightReading(stripped) {
                item.category = AuditionItemCategory.sightReading.rawValue
            } else if isOwnChoice(stripped) {
                item.category = AuditionItemCategory.solo.rawValue
            }
            items.append(analyzed(item))
            lastWasHeading = false
        }
        return items
    }

    /// Fills composer / work / movement / bars from the item's text.
    static func analyzed(_ item: ParsedListItem) -> ParsedListItem {
        var result = item
        var text: String = item.rawText
        if let prefixed = roundPrefix(text) {
            if result.round.isEmpty {
                result.round = prefixed.round
            }
            text = prefixed.rest
        }
        if let prefixed = categoryPrefix(text) {
            if item.category == AuditionItemCategory.excerpt.rawValue {
                result.category = prefixed.category.rawValue
            }
            text = prefixed.rest
        }
        let split = splitComposerWork(text)
        result.composer = split.composer
        result.work = split.work
        result.movementNumber = movementNumber(in: text)
        result.bars = barRange(in: text)
        return result
    }

    // MARK: Normalising

    /// Lower-case, accents folded, punctuation at the ends dropped, spaces collapsed.
    static func normalized(_ line: String) -> String {
        var text: String = line.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ":-–—.;,".contains(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Leading section numbering: "1. Preliminary round", "I. Final".
        text = replacing(text, pattern: "^\\(?(?:[ivx]{1,4}|[0-9]{1,2}|[a-z])[.)]\\s+", with: "")
        text = text.split(separator: " ").joined(separator: " ")
        return text
    }

    // MARK: Headings

    private static let roundSuffix: String = "(?:\\s+(?:round|rounds))?(?:\\s+(?:repertoire|excerpts|list|requirements|rep))?"

    private static let preliminaryPattern: String =
        "^(?:(?:preliminary|preliminaries|prelim|prelims)" + roundSuffix
        + "|(?:first|1st|opening)\\s+round(?:\\s+(?:repertoire|excerpts|list|requirements))?"
        + "|round\\s+(?:1|one|i)(?:\\s*[:\\-–]\\s*preliminary)?)$"

    private static let semiFinalPattern: String =
        "^(?:semi\\s*-?\\s*finals?" + roundSuffix
        + "|(?:second|2nd)\\s+round(?:\\s+(?:repertoire|excerpts|list|requirements))?"
        + "|round\\s+(?:2|two|ii)(?:\\s*[:\\-–]\\s*semi\\s*-?\\s*finals?)?)$"

    private static let finalPattern: String =
        "^(?:finals?" + roundSuffix
        + "|(?:third|3rd|last)\\s+round(?:\\s+(?:repertoire|excerpts|list|requirements))?"
        + "|round\\s+(?:3|three|iii)(?:\\s*[:\\-–]\\s*finals?)?)$"

    /// Canonical round name when the whole line is a round heading.
    static func roundHeading(_ line: String) -> String? {
        let text: String = normalized(line)
        guard !text.isEmpty, text.count <= 48 else { return nil }
        if matches(text, pattern: preliminaryPattern) { return AuditionRounds.preliminary }
        if matches(text, pattern: semiFinalPattern) { return AuditionRounds.semiFinal }
        if matches(text, pattern: finalPattern) { return AuditionRounds.final }
        return nil
    }

    private static let soloHeadingPattern: String =
        "^(?:solo|solos|solo\\s+(?:work|works|piece|pieces|repertoire|selection|selections|excerpt|excerpts|literature)"
        + "|concerto|concertos|concerto\\s+(?:movement|movements|excerpt|excerpts)|solo\\s+and\\s+concerto)$"

    private static let excerptHeadingPattern: String =
        "^(?:(?:orchestral|orchestra)\\s+(?:excerpt|excerpts|repertoire|works|passages|literature)"
        + "|excerpts|excerpt\\s+list|repertoire|repertoire\\s+list|audition\\s+repertoire|required\\s+(?:excerpts|repertoire)"
        + "|orchestral|probespielstellen|orchesterstellen)$"

    private static let chamberHeadingPattern: String = "^chamber\\s+(?:music|work|works|repertoire)$"

    /// Category when the whole line is a heading such as "Solo:" or "Orchestral excerpts".
    static func categoryHeading(_ line: String) -> AuditionItemCategory? {
        let text: String = normalized(line)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        if matches(text, pattern: soloHeadingPattern) { return .solo }
        if matches(text, pattern: excerptHeadingPattern) { return .excerpt }
        if matches(text, pattern: chamberHeadingPattern) { return .chamber }
        return nil
    }

    /// "Final: Concerto of your choice" → ("Final", "Concerto of your choice").
    static func roundPrefix(_ text: String) -> (round: String, rest: String)? {
        guard let groups = firstMatch("^(preliminary|preliminaries|prelims?|semi\\s*-?\\s*finals?|finals?|round\\s+(?:1|2|3|one|two|three|i|ii|iii))(?:\\s+round)?\\s*[:\\-–—]\\s*(.+)$",
                                      in: text), groups.count >= 3 else { return nil }
        let rest: String = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        let round: String = AuditionRounds.canonical(groups[1].replacingOccurrences(of: "  ", with: " "))
        guard round == AuditionRounds.preliminary || round == AuditionRounds.semiFinal || round == AuditionRounds.final else {
            return nil
        }
        return (round, rest)
    }

    /// "Solo: Haydn Concerto in C" → (.solo, "Haydn Concerto in C").
    static func categoryPrefix(_ text: String) -> (category: AuditionItemCategory, rest: String)? {
        guard let groups = firstMatch("^(solo|concerto|excerpt|excerpts|orchestral\\s+excerpts?|chamber\\s+music|sight\\s*-?\\s*reading)\\s*[:\\-–—]\\s*(.+)$",
                                      in: text), groups.count >= 3 else { return nil }
        let head: String = groups[1].lowercased()
        let rest: String = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if head.hasPrefix("solo") || head.hasPrefix("concerto") { return (.solo, rest) }
        if head.hasPrefix("chamber") { return (.chamber, rest) }
        if head.hasPrefix("sight") { return (.sightReading, rest) }
        return (.excerpt, rest)
    }

    // MARK: Line kinds

    /// Page numbers, rulers, lines without a single letter.
    static func isNoise(_ line: String) -> Bool {
        let text: String = normalized(line)
        if text.isEmpty { return true }
        if text.rangeOfCharacter(from: CharacterSet.letters) == nil { return true }
        if matches(text, pattern: "^(?:page|seite|p)\\s*[0-9]+(?:\\s*(?:of|/|von)\\s*[0-9]+)?$") { return true }
        return false
    }

    static func isSightReading(_ text: String) -> Bool {
        matches(normalized(text), pattern: "sight\\s*-?\\s*read")
    }

    /// "A concerto movement of your choice" → a solo, whatever heading it sits under.
    static func isOwnChoice(_ text: String) -> Bool {
        let t: String = normalized(text)
        if matches(t, pattern: "of\\s+(?:your|the\\s+candidate'?s|the\\s+applicant'?s|their)\\s+(?:own\\s+)?(?:choice|choosing)") { return true }
        if matches(t, pattern: "\\b(?:own|candidate'?s|applicant'?s|free)\\s+choice\\b") { return true }
        if matches(t, pattern: "^(?:a|one|any)\\s+(?:concerto|sonata)(?:\\s+movement)?\\b") { return true }
        return false
    }

    /// Drops "1.", "12)", "(3)", "a)", "iv)", "•", "-" from the start; everything else stays as printed.
    static func stripListMarker(_ line: String) -> String {
        var text: String = line
        text = replacing(text, pattern: "^\\(?[0-9]{1,2}[.)\\]]\\s+", with: "")
        text = replacing(text, pattern: "^\\(?[a-zA-Z]\\)\\s+", with: "")
        text = replacing(text, pattern: "^\\(?(?:[ivxIVX]{1,4})\\)\\s+", with: "")
        text = replacing(text, pattern: "^[•·▪◦‣*\\-–—]\\s+", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line that continues the previous item ("mm. 12–40", "2nd movement", "(beginning to letter B)").
    static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first.isLowercase { return true }
        if first == "(" { return true }
        let t: String = line.lowercased()
        if matches(t, pattern: "^[0-9]+\\s*(?:[–—-]|to|bis)\\s*[0-9]+") { return true }
        if matches(t, pattern: "^[0-9]+(?:st|nd|rd|th)\\b") { return true }
        if matches(t, pattern: "^(?:mm?\\.|bars?\\b|measures?\\b|meas\\.|mvts?\\b|mvt\\.|mov\\.|movt\\.|movements?\\b|reh\\.|rehearsal\\b|letter\\b|from\\b|to\\b|until\\b|through\\b|beginning\\b|pick-?up\\b|and\\b|op\\.|no\\.|hob\\.|k\\.|bwv\\b|takt\\b)") {
            return true
        }
        return false
    }

    // MARK: Composer / work

    /// Words that start a work title, not a composer's name.
    private static let workWords: Set<String> = [
        "symphony", "symphonie", "sinfonie", "sinfonia", "concerto", "konzert", "overture", "ouverture", "ouvertüre",
        "suite", "sonata", "sonate", "requiem", "mass", "messe", "serenade", "variations", "divertimento", "quartet",
        "quintet", "trio", "cantata", "oratorio", "ballet", "opera", "scherzo", "rhapsody", "fantasia", "fantasy",
        "poem", "the", "a", "an", "la", "le", "les", "der", "die", "das", "ein", "eine", "il", "el", "un", "una",
        "excerpt", "excerpts", "solo", "orchestral", "piece", "work", "any", "one", "all", "and",
    ]

    /// "Brahms: Symphony No. 2", "Brahms – Symphony No. 2", "Mozart, Symphony No. 35", "Beethoven Sym. 5/II".
    static func splitComposerWork(_ text: String) -> (composer: String?, work: String?) {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        for separator in [":", " – ", " — ", " -- ", " - "] {
            if let range = trimmed.range(of: separator) {
                let head: String = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail: String = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeComposer(head), !tail.isEmpty {
                    return (head, tail)
                }
            }
        }

        if let range = trimmed.range(of: ",") {
            let head: String = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail: String = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let headWords: Int = head.split(separator: " ").count
            if headWords <= 2, looksLikeComposer(head), let firstTail = tail.first, firstTail.isUppercase {
                return (head, tail)
            }
        }

        let words: [String] = trimmed.split(separator: " ").map { String($0) }
        if words.count >= 3, isInitial(words[0]) {
            // "R. Strauss Don Juan"
            let surname: String = words[1]
            let key: String = cleanWord(surname)
            if let firstChar = surname.first, firstChar.isUppercase, !containsDigit(surname), !workWords.contains(key), key.count >= 2 {
                let rest: String = words.dropFirst(2).joined(separator: " ")
                return (words[0] + " " + surname, rest)
            }
        }
        if words.count >= 2 {
            let first: String = words[0]
            let key: String = cleanWord(first)
            if let firstChar = first.first, firstChar.isUppercase, !containsDigit(first), !workWords.contains(key), key.count >= 2 {
                let rest: String = words.dropFirst().joined(separator: " ")
                return (first, rest)
            }
        }
        return (nil, trimmed)
    }

    /// Short, no digits, not a work-title word: "Brahms", "R. Strauss", "Strauss, R.".
    static func looksLikeComposer(_ text: String) -> Bool {
        let words: [String] = text.split(separator: " ").map { String($0) }
        guard !words.isEmpty, words.count <= 4, !containsDigit(text) else { return false }
        guard text.rangeOfCharacter(from: CharacterSet.letters) != nil else { return false }
        for word in words {
            let key: String = cleanWord(word)
            if workWords.contains(key) { return false }
        }
        return true
    }

    private static func cleanWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// "R." or "J.S." — a name initial.
    static func isInitial(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return matches(word, pattern: "^(?:[A-Z]\\.){1,3}$")
    }

    private static func containsDigit(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
    }

    // MARK: Movement

    /// Roman or arabic movement number named in the text, 1…12; `nil` when the line doesn't say.
    static func movementNumber(in text: String) -> Int? {
        let patterns: [String] = [
            "(?:\\bmvts?\\.?|\\bmvmt\\.?|\\bmov\\.?|\\bmovt\\.?|\\bmovements?|\\bsatz|\\bteil)\\s*(?:no\\.?\\s*)?([0-9]{1,2}|[ivxIVX]{1,4})\\b",
            "\\b([0-9]{1,2})(?:st|nd|rd|th)\\s+(?:mvt\\.?|mov\\.?|movt\\.?|movement)",
            "\\b([ivxIVX]{1,4})\\.?\\s*(?:satz|movement|mvt\\.?|mov\\.?)\\b",
            "/\\s*([ivxIVX]{1,4}|[0-9]{1,2})\\b",
            "[,;:]\\s*([ivxIVX]{1,4})\\b(?=\\s*(?:[,;:(]|$|mm?\\b|bars?\\b|meas))",
        ]
        for pattern in patterns {
            guard let groups = firstMatch(pattern, in: text), groups.count >= 2 else { continue }
            if let number = movementValue(groups[1]) { return number }
        }
        return nil
    }

    static func movementValue(_ token: String) -> Int? {
        if let arabic = Int(token) {
            return (1...12).contains(arabic) ? arabic : nil
        }
        guard let roman = romanValue(token) else { return nil }
        return (1...12).contains(roman) ? roman : nil
    }

    /// "ii" → 2, "iv" → 4, "xii" → 12. Only i, v and x.
    static func romanValue(_ token: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10]
        var total: Int = 0
        var previous: Int = 0
        for char in token.lowercased().reversed() {
            guard let value = values[char] else { return nil }
            if value < previous {
                total -= value
            } else {
                total += value
                previous = value
            }
        }
        return total > 0 ? total : nil
    }

    // MARK: Bars

    private static let barWord: String = "(?:\\bmm?\\.?|\\bbars?|\\bmeasures?|\\bmeas\\.?|\\btakte?|\\bt\\.)"

    /// "mm. 12–40", "bars 12 to 40", "from m. 12 to m. 40", "beginning to bar 40", "from bar 12".
    static func barRange(in text: String) -> BarRange? {
        let rangePattern: String = barWord + "\\s*([0-9]{1,4})\\s*(?:[–—-]|to|bis|through|thru|until)\\s*(?:mm?\\.?\\s*|bars?\\s*|measures?\\s*|meas\\.?\\s*)?([0-9]{1,4})\\b"
        if let groups = firstMatch(rangePattern, in: text), groups.count >= 3,
           let start = Int(groups[1]), let end = Int(groups[2]), start >= 1 {
            return BarRange(start: start, end: end >= start ? end : nil)
        }
        let fromStartPattern: String = "(?:beginning|start|opening|anfang)\\s*(?:to|until|through|thru|bis|[–—-])\\s*(?:the\\s+)?" + barWord + "?\\s*([0-9]{1,4})\\b"
        if let groups = firstMatch(fromStartPattern, in: text), groups.count >= 2, let end = Int(groups[1]), end >= 1 {
            return BarRange(start: 1, end: end)
        }
        let singlePattern: String = barWord + "\\s*([0-9]{1,4})\\b"
        if let groups = firstMatch(singlePattern, in: text), groups.count >= 2, let start = Int(groups[1]), start >= 1 {
            return BarRange(start: start, end: nil)
        }
        return nil
    }

    // MARK: Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache[pattern] = compiled
        return compiled
    }

    static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Whole match followed by its capture groups ("" for a group that didn't take part).
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let groupRange: NSRange = match.range(at: index)
            if groupRange.location == NSNotFound {
                groups.append("")
            } else if let swiftRange = Range(groupRange, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Text with the bar range and movement words taken out, for matching.
    static func textWithoutLocation(_ text: String) -> String {
        var result: String = text
        result = replacing(result, pattern: barWord + "\\s*[0-9]{1,4}\\s*(?:[–—-]|to|bis|through|thru|until)\\s*(?:mm?\\.?\\s*|bars?\\s*|measures?\\s*|meas\\.?\\s*)?[0-9]{1,4}\\b", with: " ")
        result = replacing(result, pattern: "(?:beginning|start|opening|anfang)\\s*(?:to|until|through|thru|bis|[–—-])\\s*(?:the\\s+)?" + barWord + "?\\s*[0-9]{1,4}\\b", with: " ")
        result = replacing(result, pattern: barWord + "\\s*[0-9]{1,4}\\b", with: " ")
        result = replacing(result, pattern: "(?:\\bmvts?\\.?|\\bmvmt\\.?|\\bmov\\.?|\\bmovt\\.?|\\bmovements?|\\bsatz|\\bteil)\\s*(?:no\\.?\\s*)?(?:[0-9]{1,2}|[ivxIVX]{1,4})\\b", with: " ")
        result = replacing(result, pattern: "\\b[0-9]{1,2}(?:st|nd|rd|th)\\s+(?:mvt\\.?|mov\\.?|movt\\.?|movement)", with: " ")
        result = replacing(result, pattern: "/\\s*(?:[ivxIVX]{1,4}|[0-9]{1,2})\\b", with: " ")
        result = replacing(result, pattern: "[,;:]\\s*[ivxIVX]{1,4}\\b(?=\\s*(?:[,;:(]|$|mm?\\b|bars?\\b|meas))", with: " ")
        return result.split(separator: " ").joined(separator: " ")
    }
}
