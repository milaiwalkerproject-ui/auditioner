import XCTest
@testable import Auditioner

/// Machine-translated excerpt notes (PLAN A7b, I2): language mapping, the 12 Nov 2026 date gate,
/// file decoding, and the approved-only rule. Excerpt ids and texts here are made up.
final class NoteTranslationsTests: XCTestCase {

    // MARK: - Helpers

    private func gregorian(_ timeZoneId: String) throws -> Calendar {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneId))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int, _ second: Int,
                      in calendar: Calendar) throws -> Date {
        var components: DateComponents = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(calendar.date(from: components))
    }

    /// The shape `content/sync_to_app.py` writes, with made-up excerpt ids.
    private let fixtureJSON: String = """
    {
     "generatedAt": "2026-10-11",
     "language": "es",
     "machineTranslated": true,
     "origin": "ai",
     "notes": {
      "cello-test-one": {
       "history": "Historia de prueba.",
       "technique": "Técnica de prueba.",
       "pitfalls": "Errores de prueba.",
       "practiceTips": "Consejos de prueba."
      },
      "cello-test-two": {
       "history": "Otra historia de prueba.",
       "technique": "   "
      }
     }
    }
    """

    private func fixtureFile() throws -> NoteTranslationFile {
        try JSONDecoder().decode(NoteTranslationFile.self, from: Data(fixtureJSON.utf8))
    }

    /// A store over the fixture whose gate is open (1 December 2026, Berlin) unless `now` says otherwise.
    private func fixtureTranslations(now: Date? = nil, file: NoteTranslationFile? = nil) throws -> NoteTranslations {
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let moment: Date = try now ?? date(2026, 12, 1, 12, 0, 0, in: berlin)
        let decoded: NoteTranslationFile = try file ?? fixtureFile()
        return NoteTranslations(file: decoded, languageCode: "es", calendar: berlin, now: { moment })
    }

    /// Builds an excerpt the way the app does (JSON), with made-up prose. `approved` lists the
    /// fields whose review status is "approved"; the others are drafts.
    private func makeExcerpt(id: String,
                             fields: [String],
                             approved: [String],
                             origin: String = "ai") throws -> Excerpt {
        var prose: [String] = []
        for field in fields {
            let status: String = approved.contains(field) ? "approved" : "draft"
            prose.append("\"\(field)\": {\"text\": \"English \(field).\", \"origin\": \"\(origin)\", \"reviewStatus\": \"\(status)\"}")
        }
        let json: String = """
        {"id": "\(id)", "instrument": "cello", "positions": ["section"], "composer": "Ada Quill",
         "work": "Test Work", "title": "Opening", "location": {"status": "unverified"}, "sources": [],
         "listingStatus": "published", "prose": {\(prose.joined(separator: ", "))}}
        """
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    // MARK: - Language code mapping

    func testSupportedCodesMapToThemselves() {
        for code in NoteTranslationLanguage.supported {
            XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: [code]), code)
        }
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["pt-BR", "en"]), "pt-BR")
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["zh-Hant"]), "zh-Hant")
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["zh-Hans"]), "zh-Hans")
    }

    func testEnglishAndUnknownLanguagesHaveNoCode() {
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["en"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["en-GB", "de"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["xx"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["nl"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: [""]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: []))
    }

    func testOnlyTheFirstPreferredLocalizationCounts() {
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["en", "es"]))
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["es", "en"]), "es")
    }

    func testVariantsFallBackToTheLanguageButScriptIsNeverGuessed() {
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["es-MX"]), "es")
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["de_AT"]), "de")
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["PT-br"]), "pt-BR")
        XCTAssertEqual(NoteTranslationLanguage.code(forPreferredLocalizations: ["zh-hant"]), "zh-Hant")
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["zh"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["pt"]))
        XCTAssertNil(NoteTranslationLanguage.code(forPreferredLocalizations: ["pt-PT"]))
    }

    // MARK: - Date gate

    func testGateOpensWhen12NovemberHasBegunEverywhere() throws {
        // Midnight at UTC-12 is 12:00 UTC: the first moment it is 12 November in every time zone.
        let utc: Calendar = try gregorian("UTC")
        let justBefore: Date = try date(2026, 11, 12, 11, 59, 59, in: utc)
        let boundary: Date = try date(2026, 11, 12, 12, 0, 0, in: utc)
        let justAfter: Date = try date(2026, 11, 12, 12, 0, 1, in: utc)
        XCTAssertFalse(MachineTranslation.isOpen(now: justBefore, calendar: utc))
        XCTAssertTrue(MachineTranslation.isOpen(now: boundary, calendar: utc))
        XCTAssertTrue(MachineTranslation.isOpen(now: justAfter, calendar: utc))
        XCTAssertEqual(MachineTranslation.showFrom(calendar: utc), boundary)
    }

    func testGateIsOneMomentInEveryTimeZone() throws {
        let utc: Calendar = try gregorian("UTC")
        let boundary: Date = try date(2026, 11, 12, 12, 0, 0, in: utc)
        for zone in ["Europe/Berlin", "Pacific/Auckland", "America/Los_Angeles", "Pacific/Kiritimati", "Etc/GMT+12"] {
            let calendar: Calendar = try gregorian(zone)
            XCTAssertEqual(MachineTranslation.showFrom(calendar: calendar), boundary, zone)
        }
        // Local midnight on 12 November is not enough anywhere east of UTC-12.
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let auckland: Calendar = try gregorian("Pacific/Auckland")
        let berlinMidnight: Date = try date(2026, 11, 12, 0, 0, 0, in: berlin)
        let aucklandMidnight: Date = try date(2026, 11, 12, 0, 0, 0, in: auckland)
        XCTAssertFalse(MachineTranslation.isOpen(now: berlinMidnight, calendar: berlin))
        XCTAssertFalse(MachineTranslation.isOpen(now: aucklandMidnight, calendar: auckland))
        // 12:00 UTC is 04:00 on 12 November in Los Angeles (UTC-8 in November).
        let losAngeles: Calendar = try gregorian("America/Los_Angeles")
        let losAngelesFour: Date = try date(2026, 11, 12, 4, 0, 0, in: losAngeles)
        let losAngelesJustBefore: Date = try date(2026, 11, 12, 3, 59, 59, in: losAngeles)
        XCTAssertTrue(MachineTranslation.isOpen(now: losAngelesFour, calendar: losAngeles))
        XCTAssertFalse(MachineTranslation.isOpen(now: losAngelesJustBefore, calendar: losAngeles))
    }

    func testGateIsClosedTodayAndOpenLater() throws {
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let today: Date = try date(2026, 10, 11, 12, 0, 0, in: berlin)
        let later: Date = try date(2027, 1, 1, 0, 0, 0, in: berlin)
        XCTAssertFalse(MachineTranslation.isOpen(now: today, calendar: berlin))
        XCTAssertTrue(MachineTranslation.isOpen(now: later, calendar: berlin))
    }

    func testGateUsesGregorianDayWhateverCalendarTheDeviceCounts() throws {
        // A Buddhist calendar numbers 2026 as 2569; the gate must still mean the same instant.
        let berlin: Calendar = try gregorian("Europe/Berlin")
        var buddhist: Calendar = Calendar(identifier: .buddhist)
        buddhist.timeZone = berlin.timeZone
        XCTAssertEqual(MachineTranslation.showFrom(calendar: buddhist), MachineTranslation.showFrom(calendar: berlin))
    }

    // MARK: - File decoding

    func testFixtureDecodes() throws {
        let file: NoteTranslationFile = try fixtureFile()
        XCTAssertEqual(file.language, "es")
        XCTAssertEqual(file.origin, "ai")
        XCTAssertEqual(file.machineTranslated, true)
        XCTAssertEqual(file.generatedAt, "2026-10-11")
        XCTAssertEqual(file.notes.count, 2)
        XCTAssertEqual(file.notes["cello-test-one"]?["history"], "Historia de prueba.")
        XCTAssertEqual(file.notes["cello-test-one"]?["practiceTips"], "Consejos de prueba.")
        XCTAssertEqual(file.text(excerptId: "cello-test-two", field: "history"), "Otra historia de prueba.")
    }

    func testMissingNoteOrFieldOrBlankTextMeansEnglish() throws {
        let file: NoteTranslationFile = try fixtureFile()
        XCTAssertNil(file.text(excerptId: "cello-test-missing", field: "history"))
        XCTAssertNil(file.text(excerptId: "cello-test-two", field: "pitfalls"))
        XCTAssertNil(file.text(excerptId: "cello-test-two", field: "technique"), "whitespace-only text is not a translation")
        let translations: NoteTranslations = try fixtureTranslations()
        XCTAssertTrue(translations.isGateOpen)
        XCTAssertNil(translations.translation(excerptId: "cello-test-missing", field: "history"))
        XCTAssertEqual(translations.translation(excerptId: "cello-test-one", field: "history"), "Historia de prueba.")
    }

    func testMinimalFileDecodesWithoutOptionalFields() throws {
        let json: String = #"{"language": null, "notes": {}}"#
        let file: NoteTranslationFile = try JSONDecoder().decode(NoteTranslationFile.self, from: Data(json.utf8))
        XCTAssertNil(file.language)
        XCTAssertNil(file.machineTranslated)
        XCTAssertTrue(file.notes.isEmpty)
        let translations: NoteTranslations = try fixtureTranslations(file: file)
        XCTAssertFalse(translations.hasTranslations)
        XCTAssertNil(translations.translation(excerptId: "cello-test-one", field: "history"))
    }

    // MARK: - Store

    func testClosedGateOffersNoTranslationEvenWhenOneExists() throws {
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let before: Date = try date(2026, 11, 11, 23, 59, 59, in: berlin)
        let translations: NoteTranslations = try fixtureTranslations(now: before)
        XCTAssertTrue(translations.hasTranslations)
        XCTAssertFalse(translations.isGateOpen)
        XCTAssertNil(translations.translation(excerptId: "cello-test-one", field: "history"))
        let at: Date = try date(2026, 11, 12, 0, 0, 0, in: berlin)
        let open: NoteTranslations = try fixtureTranslations(now: at)
        XCTAssertEqual(open.translation(excerptId: "cello-test-one", field: "history"), "Historia de prueba.")
    }

    func testMissingFileMeansNoTranslations() throws {
        // The test bundle ships no notes-<code>.json.
        let testBundle: Bundle = Bundle(for: NoteTranslationsTests.self)
        XCTAssertNil(NoteTranslations.load(code: "es", from: testBundle))
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let later: Date = try date(2027, 1, 1, 0, 0, 0, in: berlin)
        let translations: NoteTranslations = NoteTranslations(bundle: testBundle,
                                                              preferredLocalizations: ["es"],
                                                              calendar: berlin,
                                                              now: { later })
        XCTAssertEqual(translations.languageCode, "es")
        XCTAssertNil(translations.file)
        XCTAssertFalse(translations.hasTranslations)
        XCTAssertNil(translations.translation(excerptId: "cello-test-one", field: "history"))
    }

    func testEnglishAndUnknownLanguagesLoadNothingFromTheAppBundle() {
        let appBundle: Bundle = Bundle(for: CatalogStore.self)
        let english: NoteTranslations = NoteTranslations(bundle: appBundle, preferredLocalizations: ["en"])
        XCTAssertNil(english.languageCode)
        XCTAssertNil(english.file)
        let unknown: NoteTranslations = NoteTranslations(bundle: appBundle, preferredLocalizations: ["xx"])
        XCTAssertNil(unknown.languageCode)
        XCTAssertNil(unknown.file)
    }

    func testBundledTranslationFilesDecodeAndCoverOnlyApprovedNotes() throws {
        // Every notes-<code>.json the app ships: decodable, named after its language, and every
        // entry points at an approved English note of a catalogue excerpt (the honesty contract).
        let appBundle: Bundle = Bundle(for: CatalogStore.self)
        let store: CatalogStore = CatalogStore(bundle: appBundle)
        let urls: [URL] = (appBundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
        let validFields: Set<String> = ["history", "technique", "pitfalls", "practiceTips"]
        for url in urls {
            let name: String = url.deletingPathExtension().lastPathComponent
            let code: String = String(name.dropFirst("notes-".count))
            XCTAssertTrue(NoteTranslationLanguage.supported.contains(code), "\(name) is not a supported language")
            let file: NoteTranslationFile = try XCTUnwrap(NoteTranslations.load(code: code, from: appBundle),
                                                          "\(url.lastPathComponent) does not decode")
            XCTAssertEqual(file.language, code, "\(url.lastPathComponent) says it is \(file.language ?? "nil")")
            XCTAssertEqual(file.machineTranslated, true, "\(url.lastPathComponent) must say machineTranslated")
            XCTAssertEqual(file.origin, "ai", "\(url.lastPathComponent) must say origin ai")
            for (excerptId, fields) in file.notes {
                let excerpt: Excerpt = try XCTUnwrap(store.excerpt(id: excerptId), "\(name): \(excerptId) is not in the catalogue")
                for (field, text) in fields {
                    XCTAssertTrue(validFields.contains(field), "\(name): \(excerptId).\(field) is not a note field")
                    XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name): \(excerptId).\(field) is empty")
                    let block: ProseBlock? = {
                        switch field {
                        case "history": return excerpt.prose?.history
                        case "technique": return excerpt.prose?.technique
                        case "pitfalls": return excerpt.prose?.pitfalls
                        case "practiceTips": return excerpt.prose?.practiceTips
                        default: return nil
                        }
                    }()
                    XCTAssertEqual(block?.isApproved, true, "\(name): \(excerptId).\(field) is translated but the English is not approved")
                }
            }
        }
    }

    // MARK: - Display

    func testDisplayShowsTranslationFirstAndOriginalOnRequest() {
        XCTAssertEqual(NoteTranslationDisplay.text(original: "English.", translation: "Español.", showsOriginal: false), "Español.")
        XCTAssertEqual(NoteTranslationDisplay.text(original: "English.", translation: "Español.", showsOriginal: true), "English.")
        XCTAssertEqual(NoteTranslationDisplay.text(original: "English.", translation: nil, showsOriginal: false), "English.")
        XCTAssertEqual(NoteTranslationDisplay.text(original: "English.", translation: nil, showsOriginal: true), "English.")
        XCTAssertTrue(NoteTranslationDisplay.showsMachineTranslatedTag(translation: "Español.", showsOriginal: false))
        XCTAssertFalse(NoteTranslationDisplay.showsMachineTranslatedTag(translation: "Español.", showsOriginal: true))
        XCTAssertFalse(NoteTranslationDisplay.showsMachineTranslatedTag(translation: nil, showsOriginal: false))
    }

    // MARK: - Approved-only rule on the page

    func testApprovedNotesCarryTheirTranslationInPageOrder() throws {
        let excerpt: Excerpt = try makeExcerpt(id: "cello-test-one",
                                               fields: ["practiceTips", "history", "technique", "pitfalls"],
                                               approved: ["history", "technique", "pitfalls", "practiceTips"])
        let items: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: false,
                                                                        translations: try fixtureTranslations())
        XCTAssertEqual(items.map { $0.id }, ["history", "technique", "pitfalls", "practiceTips"])
        XCTAssertEqual(items.map { $0.translation }, ["Historia de prueba.", "Técnica de prueba.", "Errores de prueba.", "Consejos de prueba."])
        XCTAssertEqual(items.map { $0.block.text }, ["English history.", "English technique.", "English pitfalls.", "English practiceTips."])
    }

    func testDraftNotesAreNeverTranslatedEvenInReviewerMode() throws {
        let excerpt: Excerpt = try makeExcerpt(id: "cello-test-one", fields: ["history", "technique"], approved: ["history"])
        let translations: NoteTranslations = try fixtureTranslations()

        let forPlayers: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: false, translations: translations)
        XCTAssertEqual(forPlayers.map { $0.id }, ["history"], "a draft is not listed at all for players")
        XCTAssertEqual(forPlayers.first?.translation, "Historia de prueba.")

        let forReviewer: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: true, translations: translations)
        XCTAssertEqual(forReviewer.map { $0.id }, ["history", "technique"])
        XCTAssertEqual(forReviewer[0].translation, "Historia de prueba.")
        XCTAssertNil(forReviewer[1].translation, "the draft shows its English, with the draft banner")
    }

    func testClosedGateLeavesEveryNoteInEnglish() throws {
        let excerpt: Excerpt = try makeExcerpt(id: "cello-test-one", fields: ["history"], approved: ["history"])
        let berlin: Calendar = try gregorian("Europe/Berlin")
        let today: Date = try date(2026, 10, 11, 12, 0, 0, in: berlin)
        let items: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: false,
                                                                        translations: try fixtureTranslations(now: today))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.translation)
        XCTAssertEqual(items.first?.block.text, "English history.")
    }

    func testUntranslatedExcerptStaysEnglish() throws {
        let excerpt: Excerpt = try makeExcerpt(id: "cello-test-missing", fields: ["history"], approved: ["history"])
        let items: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: false,
                                                                        translations: try fixtureTranslations())
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.translation)
    }

    func testExcerptWithoutProseHasNoItems() throws {
        let excerpt: Excerpt = try makeExcerpt(id: "cello-test-one", fields: [], approved: [])
        let items: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: true,
                                                                        translations: try fixtureTranslations())
        XCTAssertTrue(items.isEmpty)
    }
}
