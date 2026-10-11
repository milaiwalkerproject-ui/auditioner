import Foundation

/// Pure helpers behind "Report an error" / "Send feedback": message trimming and limits,
/// the server's rules for the `context` field, and plain-words titles. No UI and no
/// SwiftData here so the unit tests can call everything directly.
///
/// Server contract (backend/app/main.py, POST /v1/feedback):
///   context    1–64 characters, only a–z, 0–9, ':' and '-'
///   excerptId  optional, at most 128 characters
///   message    1–2000 characters after trimming
enum FeedbackLogic {
    static let maxMessageLength: Int = 2000
    static let maxContextLength: Int = 64
    static let maxExcerptIdLength: Int = 128

    private static let allowedContextCharacters: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789:-")

    // MARK: Message

    /// What the user typed, trimmed and cut to the server's limit. Empty means "nothing to send".
    static func cleanMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxMessageLength {
            return String(trimmed.prefix(maxMessageLength))
        }
        return trimmed
    }

    /// Applied while typing so the editor never holds more than the limit (whitespace is kept).
    static func clamped(_ raw: String) -> String {
        if raw.count > maxMessageLength {
            return String(raw.prefix(maxMessageLength))
        }
        return raw
    }

    static func canSend(_ raw: String) -> Bool {
        !cleanMessage(raw).isEmpty
    }

    /// "123/2000" under the text field.
    static func counterText(_ raw: String) -> String {
        let count: Int = min(raw.count, maxMessageLength)
        return "\(count)/\(maxMessageLength)"
    }

    // MARK: Context and excerpt id

    /// Lowercases and drops anything the server would refuse; never empty ("app" when nothing is left).
    static func cleanContext(_ raw: String) -> String {
        let lowered: String = raw.lowercased()
        let kept: String = lowered.filter { allowedContextCharacters.contains($0) }
        let cut: String = String(kept.prefix(maxContextLength))
        return cut.isEmpty ? "app" : cut
    }

    static func cleanExcerptId(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(maxExcerptIdLength))
    }

    /// Contexts that start with "excerpt" come from an excerpt page: the sheet is called "Report an error" there.
    static func isExcerptContext(_ context: String) -> Bool {
        cleanContext(context).hasPrefix("excerpt")
    }

    // MARK: Words

    static func title(for context: String) -> String {
        if isExcerptContext(context) {
            return String(localized: "Report an error")
        }
        return String(localized: "Send feedback")
    }

    /// Heading above the text field.
    static func prompt(for context: String) -> String {
        if isExcerptContext(context) {
            return String(localized: "What's wrong?")
        }
        return String(localized: "What would you like to tell us?")
    }

    /// Where in the app the report comes from, in plain words (shown in the sheet so the player
    /// knows what the message will be attached to).
    static func contextDescription(_ context: String) -> String {
        let cleaned = cleanContext(context)
        let notePrefix = "excerpt-note:"
        if cleaned.hasPrefix(notePrefix) {
            let key = String(cleaned.dropFirst(notePrefix.count))
            let section = noteSectionName(key)
            return String(localized: "Excerpt notes — \(section)")
        }
        switch cleaned {
        case "excerpt-fact": return String(localized: "Excerpt facts")
        case "excerpt-recording": return String(localized: "Excerpt recordings")
        case "settings": return String(localized: "General feedback")
        case "scan": return String(localized: "Scanning a part")
        case "practice": return String(localized: "Practice tools")
        default: return humanize(cleaned)
        }
    }

    /// The prose block keys used by the excerpt page ("history", "technique", "pitfalls", "practiceTips"),
    /// already lowercased by `cleanContext`.
    static func noteSectionName(_ key: String) -> String {
        switch key {
        case "history": return String(localized: "History")
        case "technique": return String(localized: "Technique")
        case "pitfalls": return String(localized: "Common pitfalls")
        case "practicetips": return String(localized: "Practice tips")
        default: return humanize(key)
        }
    }

    /// "mock-audition:timer" → "Mock audition timer".
    static func humanize(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words: [String] = spaced.split(separator: " ").map { String($0) }
        guard let first = words.first else { return raw }
        let rest: [String] = Array(words.dropFirst())
        return ([first.capitalized] + rest).joined(separator: " ")
    }
}
