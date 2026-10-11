import Foundation
import Combine

// Machine-translated excerpt notes (PLAN A7b, I2). The English note in the catalogue is the
// source of truth; `content/sync_to_app.py` ships, per language, only translations whose English
// is unchanged, as Resources/Translations/notes-<code>.json. Work titles, composer names and score
// markings are never in these files. Nothing here invents a fact: a translation is shown or the
// English is, and either way the AI label on an AI note stays.

/// The date gate: translated notes are offered only from 12 November 2026 (the I2 date), 00:00 in
/// the device's time zone. Pure, so it can be unit-tested.
enum MachineTranslation {
    /// 12 November 2026 as a Gregorian date, without a time zone.
    static let showFromComponents: DateComponents = DateComponents(year: 2026, month: 11, day: 12)

    /// Midnight at the start of 12 November 2026 in `calendar`'s time zone. The day is a Gregorian
    /// date whatever calendar the device counts in (a Buddhist or Japanese calendar numbers the
    /// years differently), so only the time zone is taken from `calendar`.
    static func showFrom(calendar: Calendar) -> Date? {
        var gregorian: Calendar = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: showFromComponents)
    }

    /// True when translations may be shown: `now` is at or after `showFrom(calendar:)`.
    static func isOpen(now: Date, calendar: Calendar) -> Bool {
        guard let from: Date = showFrom(calendar: calendar) else { return false }
        return now >= from
    }
}

/// Which notes-<code>.json belongs to the app's current language.
enum NoteTranslationLanguage {
    /// The languages notes are translated into (PLAN A7), spelled as the resource-name suffix.
    static let supported: [String] = ["es", "zh-Hans", "zh-Hant", "it", "ru", "ja", "ko", "de", "fr", "pt-BR"]

    /// The code for the first of `preferredLocalizations` (as `Bundle.main.preferredLocalizations`
    /// gives them, best match first), or nil for English and for languages without notes.
    /// Matching ignores case and accepts "_" for "-"; a regional variant falls back to its language
    /// ("es-MX" → "es"); "zh" on its own matches nothing — Simplified or Traditional is never guessed.
    static func code(forPreferredLocalizations preferredLocalizations: [String]) -> String? {
        guard let first: String = preferredLocalizations.first else { return nil }
        let normalized: String = first
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let exact: String = supported.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return exact
        }
        let base: String = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return supported.first(where: { $0.caseInsensitiveCompare(base) == .orderedSame })
    }
}

/// One notes-<code>.json as `content/sync_to_app.py` writes it.
struct NoteTranslationFile: Decodable, Equatable {
    var language: String?
    var origin: String?
    var machineTranslated: Bool?
    var generatedAt: String?
    /// excerpt id → field ("history", "technique", "pitfalls", "practiceTips") → translated text.
    var notes: [String: [String: String]]

    /// The translated text for one note, or nil when the file has none (or only whitespace).
    func text(excerptId: String, field: String) -> String? {
        guard let translated: String = notes[excerptId]?[field] else { return nil }
        let trimmed: String = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : translated
    }
}

/// Machine-translated excerpt notes for the app's current language. Loads the one bundled file
/// for that language once; `translation(excerptId:field:)` answers nil — show the English — when
/// the app runs in English or a language without notes, when the note has no translation, and
/// while the date gate (`MachineTranslation`) is closed. Views hold it the way they hold the other
/// singletons: `@ObservedObject private var translations: NoteTranslations = NoteTranslations.shared`.
final class NoteTranslations: ObservableObject {
    static let shared: NoteTranslations = NoteTranslations()

    /// "es", "zh-Hant", … or nil when the app runs in English or a language without notes.
    let languageCode: String?
    /// The decoded file for `languageCode`, nil when there is none in the bundle.
    let file: NoteTranslationFile?

    private let calendar: Calendar
    private let now: () -> Date

    /// `preferredLocalizations` defaults to the bundle's own (what iOS chose for the app).
    init(bundle: Bundle = .main,
         preferredLocalizations: [String]? = nil,
         calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() }) {
        let localizations: [String] = preferredLocalizations ?? bundle.preferredLocalizations
        let code: String? = NoteTranslationLanguage.code(forPreferredLocalizations: localizations)
        self.languageCode = code
        self.file = code.flatMap { (c: String) -> NoteTranslationFile? in
            NoteTranslations.load(code: c, from: bundle)
        }
        self.calendar = calendar
        self.now = now
    }

    /// For tests and previews: an already decoded file instead of a bundle.
    init(file: NoteTranslationFile?,
         languageCode: String?,
         calendar: Calendar,
         now: @escaping () -> Date) {
        self.languageCode = languageCode
        self.file = file
        self.calendar = calendar
        self.now = now
    }

    /// Reads notes-<code>.json from `bundle`. The folder-synchronised group flattens Resources/
    /// subfolders, so the file is looked up by name only (as the catalogue files are).
    static func load(code: String, from bundle: Bundle) -> NoteTranslationFile? {
        guard let url: URL = bundle.url(forResource: "notes-\(code)", withExtension: "json") else { return nil }
        guard let data: Data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteTranslationFile.self, from: data)
    }

    /// Whether the I2 date has passed on this device.
    var isGateOpen: Bool {
        MachineTranslation.isOpen(now: now(), calendar: calendar)
    }

    /// True when a file with at least one note is loaded (regardless of the gate).
    var hasTranslations: Bool {
        guard let file: NoteTranslationFile = file else { return false }
        return !file.notes.isEmpty
    }

    /// The translation to offer for one note, or nil to show the English. Callers must still apply
    /// the approved-only rule first: this answers for any id it is asked about.
    func translation(excerptId: String, field: String) -> String? {
        guard isGateOpen, let file: NoteTranslationFile = file else { return nil }
        return file.text(excerptId: excerptId, field: field)
    }
}

/// What one note on the page shows: the translation when there is one and the player hasn't tapped
/// "Show original", otherwise the English. Pure, so it can be unit-tested.
enum NoteTranslationDisplay {
    static func text(original: String, translation: String?, showsOriginal: Bool) -> String {
        guard let translation: String = translation, !showsOriginal else { return original }
        return translation
    }

    /// The "Machine-translated" pill belongs next to translated text only.
    static func showsMachineTranslatedTag(translation: String?, showsOriginal: Bool) -> Bool {
        translation != nil && !showsOriginal
    }
}
