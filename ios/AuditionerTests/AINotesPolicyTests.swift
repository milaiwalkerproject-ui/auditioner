import XCTest
@testable import Auditioner

/// PLAN A6: Hong Kong and Macau get the app with AI notes hidden. The storefront decides; the device
/// region only when the storefront is unknown. Excerpt ids and texts here are made up.
final class AINotesPolicyTests: XCTestCase {

    // MARK: - The rule

    func testHongKongAndMacauStorefrontsHideAINotes() {
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: "HKG", localeRegion: nil))
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: "MAC", localeRegion: nil))
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: "hkg", localeRegion: "US"), "case doesn't matter")
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: " MAC ", localeRegion: "DE"), "whitespace doesn't matter")
    }

    func testAKnownStorefrontElsewhereShowsAINotesWhateverTheDeviceRegion() {
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: "USA", localeRegion: "HK"))
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: "DEU", localeRegion: "MO"))
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: "GBR", localeRegion: nil))
    }

    func testWithoutAStorefrontTheDeviceRegionDecides() {
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: "HK"))
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: "MO"))
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: "", localeRegion: "hk"), "an empty storefront is unknown")
        XCTAssertTrue(AINotesPolicy.hidesAINotes(storefrontCountry: "   ", localeRegion: "MO"))
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: "US"))
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: "CN"), "mainland China is excluded as a storefront (A6), not handled here")
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: ""))
        XCTAssertFalse(AINotesPolicy.hidesAINotes(storefrontCountry: nil, localeRegion: nil), "nothing known → nothing hidden")
    }

    // MARK: - The cached answer

    @MainActor
    func testAvailabilityStartsFromTheDeviceRegionAndThenFollowsTheStorefront() {
        let inHongKong: AINotesAvailability = AINotesAvailability(localeRegion: "HK")
        XCTAssertTrue(inHongKong.hidesAINotes, "before StoreKit answers, the device region decides")
        inHongKong.apply(storefrontCountry: "USA")
        XCTAssertFalse(inHongKong.hidesAINotes, "a US storefront shows the notes even on a Hong Kong device")
        XCTAssertEqual(inHongKong.storefrontCountry, "USA")

        let elsewhere: AINotesAvailability = AINotesAvailability(localeRegion: "FR")
        XCTAssertFalse(elsewhere.hidesAINotes)
        elsewhere.apply(storefrontCountry: "MAC")
        XCTAssertTrue(elsewhere.hidesAINotes, "a Macau storefront hides them whatever the device region")
        elsewhere.apply(storefrontCountry: nil)
        XCTAssertFalse(elsewhere.hidesAINotes, "no storefront → back to the device region")
    }

    // MARK: - What the notes section lists

    private func gregorian(_ timeZoneId: String) throws -> Calendar {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneId))
        return calendar
    }

    /// A translations store whose gate is open (1 December 2026), with a translation for every field.
    private func openTranslations() throws -> NoteTranslations {
        let json: String = """
        {"language": "es", "machineTranslated": true, "origin": "ai",
         "notes": {"cello-test-one": {"history": "Historia de prueba.", "technique": "Técnica de prueba.",
                                      "pitfalls": "Errores de prueba.", "practiceTips": "Consejos de prueba."}}}
        """
        let file: NoteTranslationFile = try JSONDecoder().decode(NoteTranslationFile.self, from: Data(json.utf8))
        let berlin: Calendar = try gregorian("Europe/Berlin")
        var components: DateComponents = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 1
        components.hour = 12
        let moment: Date = try XCTUnwrap(berlin.date(from: components))
        return NoteTranslations(file: file, languageCode: "es", calendar: berlin, now: { moment })
    }

    /// An excerpt the way the app builds it (JSON): `fields` maps a note field to its origin, all approved
    /// unless listed in `drafts`.
    private func makeExcerpt(fields: [(field: String, origin: String)], drafts: [String] = []) throws -> Excerpt {
        let prose: [String] = fields.map { entry in
            let status: String = drafts.contains(entry.field) ? "draft" : "approved"
            return "\"\(entry.field)\": {\"text\": \"English \(entry.field).\", \"origin\": \"\(entry.origin)\", \"reviewStatus\": \"\(status)\"}"
        }
        let json: String = """
        {"id": "cello-test-one", "instrument": "cello", "positions": ["section"], "composer": "Ada Quill",
         "work": "Test Work", "title": "Opening", "location": {"status": "unverified"}, "sources": [],
         "listingStatus": "published", "prose": {\(prose.joined(separator: ", "))}}
        """
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    func testHiddenRegionDropsAINotesAndTranslationsButKeepsCuratedNotesInEnglish() throws {
        let excerpt: Excerpt = try makeExcerpt(fields: [
            (field: "history", origin: "curated"),
            (field: "technique", origin: "ai"),
            (field: "pitfalls", origin: "ai"),
            (field: "practiceTips", origin: "curated"),
        ])
        let translations: NoteTranslations = try openTranslations()

        let shown: ExcerptNotesListing = ExcerptNotesLogic.listing(for: excerpt, reviewerMode: false,
                                                                   translations: translations, hidesAINotes: false)
        XCTAssertEqual(shown.items.map { $0.id }, ["history", "technique", "pitfalls", "practiceTips"])
        XCTAssertEqual(shown.items.map { $0.translation }, ["Historia de prueba.", "Técnica de prueba.", "Errores de prueba.", "Consejos de prueba."])
        XCTAssertEqual(shown.hiddenByRegion, 0)

        let hidden: ExcerptNotesListing = ExcerptNotesLogic.listing(for: excerpt, reviewerMode: false,
                                                                    translations: translations, hidesAINotes: true)
        XCTAssertEqual(hidden.items.map { $0.id }, ["history", "practiceTips"], "AI notes are not listed at all")
        XCTAssertEqual(hidden.items.map { $0.block.text }, ["English history.", "English practiceTips."])
        XCTAssertEqual(hidden.items.map { $0.translation }, [nil, nil], "a machine translation is AI prose: none is offered")
        XCTAssertEqual(hidden.hiddenByRegion, 2, "the section says once that some notes aren't available")
    }

    func testHiddenRegionAppliesInReviewerModeToo() throws {
        let excerpt: Excerpt = try makeExcerpt(fields: [
            (field: "history", origin: "ai"),
            (field: "technique", origin: "ai"),
            (field: "pitfalls", origin: "curated"),
        ], drafts: ["technique", "pitfalls"])
        let translations: NoteTranslations = try openTranslations()

        let reviewer: ExcerptNotesListing = ExcerptNotesLogic.listing(for: excerpt, reviewerMode: true,
                                                                      translations: translations, hidesAINotes: true)
        XCTAssertEqual(reviewer.items.map { $0.id }, ["pitfalls"], "the curated draft shows (reviewer mode), the AI ones never")
        XCTAssertNil(reviewer.items.first?.translation)
        XCTAssertEqual(reviewer.hiddenByRegion, 2)

        let player: ExcerptNotesListing = ExcerptNotesLogic.listing(for: excerpt, reviewerMode: false,
                                                                    translations: translations, hidesAINotes: true)
        XCTAssertTrue(player.items.isEmpty)
        XCTAssertEqual(player.hiddenByRegion, 1, "only the approved AI note counts: the AI draft was not going to be shown anyway")
    }

    func testNothingHiddenWhenTheExcerptHasOnlyCuratedNotes() throws {
        let excerpt: Excerpt = try makeExcerpt(fields: [(field: "history", origin: "curated")])
        let listing: ExcerptNotesListing = ExcerptNotesLogic.listing(for: excerpt, reviewerMode: false,
                                                                     translations: try openTranslations(), hidesAINotes: true)
        XCTAssertEqual(listing.items.map { $0.id }, ["history"])
        XCTAssertEqual(listing.hiddenByRegion, 0, "no notice when nothing was left out")
    }

    func testProseItemsKeepsTheOldShapeWithTheRegionRuleOff() throws {
        let excerpt: Excerpt = try makeExcerpt(fields: [(field: "history", origin: "ai")])
        let items: [ExcerptProseItem] = ExcerptNotesLogic.proseItems(for: excerpt, reviewerMode: false,
                                                                     translations: try openTranslations())
        XCTAssertEqual(items.map { $0.id }, ["history"])
        XCTAssertEqual(items.first?.translation, "Historia de prueba.")
    }
}
