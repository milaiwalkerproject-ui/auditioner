import XCTest
@testable import Auditioner

/// `auditioner://` links (PLAN U1). Fixtures are made up: "Example Philharmonic", invented dates, example.org.
final class DeepLinkTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func parse(_ text: String) -> DeepLink? {
        guard let url = URL(string: text) else {
            XCTFail("not a URL: \(text)")
            return nil
        }
        return DeepLink.parse(url, calendar: calendar)
    }

    private func ymd(_ date: Date?) -> [Int]? {
        guard let date = date else { return nil }
        let parts: DateComponents = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0]
    }

    private func prefill(_ text: String) -> AuditionPrefill? {
        guard case .newAudition(let prefill)? = parse(text) else {
            XCTFail("expected a new-audition link: \(text)")
            return nil
        }
        return prefill
    }

    /// Builds an excerpt the way the app does (JSON); a made-up composer and work.
    private func makeExcerpt(id: String) throws -> Excerpt {
        let json: String = """
        {"id": "\(id)", "instrument": "cello", "positions": ["section"], "composer": "Ada Quill",
         "work": "Symphony No. 2 in D major", "title": "Opening", "location": {"status": "unverified"},
         "sources": [], "listingStatus": "published"}
        """
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    // MARK: Excerpt links

    func testExcerptLinkParses() {
        XCTAssertEqual(parse("auditioner://excerpt/cello-quill-symphony-2-mvt2"),
                       .excerpt(id: "cello-quill-symphony-2-mvt2"))
    }

    func testExcerptLinkToleratesTrailingSlashSchemeCaseAndNoHost() {
        XCTAssertEqual(parse("auditioner://excerpt/cello-quill-symphony-2-mvt2/"), .excerpt(id: "cello-quill-symphony-2-mvt2"))
        XCTAssertEqual(parse("AUDITIONER://excerpt/cello-quill-symphony-2-mvt2"), .excerpt(id: "cello-quill-symphony-2-mvt2"))
        XCTAssertEqual(parse("auditioner:///excerpt/cello-quill-symphony-2-mvt2"), .excerpt(id: "cello-quill-symphony-2-mvt2"))
    }

    func testExcerptLinkDecodesPercentEncodingAndTrims() {
        XCTAssertEqual(parse("auditioner://excerpt/%20cello-quill-symphony-2-mvt2%20"), .excerpt(id: "cello-quill-symphony-2-mvt2"))
    }

    func testExcerptLinkIsCappedAtTwoHundredCharacters() {
        let long: String = String(repeating: "a", count: 250)
        guard case .excerpt(let id)? = parse("auditioner://excerpt/\(long)") else {
            return XCTFail("expected an excerpt link")
        }
        XCTAssertEqual(id.count, 200)
    }

    func testExcerptLinkNeedsExactlyOneId() {
        XCTAssertNil(parse("auditioner://excerpt"))
        XCTAssertNil(parse("auditioner://excerpt/"))
        XCTAssertNil(parse("auditioner://excerpt/a/b"))
    }

    // MARK: Other links

    func testOtherSchemesAndUnknownKindsAreIgnored() {
        XCTAssertNil(parse("https://example.org/excerpt/cello-quill-symphony-2-mvt2"))
        XCTAssertNil(parse("tutti://excerpt/cello-quill-symphony-2-mvt2"))
        XCTAssertNil(parse("auditioner://settings"))
        XCTAssertNil(parse("auditioner://audition"))
        XCTAssertNil(parse("auditioner://audition/edit"))
        XCTAssertNil(parse("auditioner://audition/new/extra"))
        if let bare = URL(string: "auditioner://") {
            XCTAssertNil(DeepLink.parse(bare, calendar: calendar))
        }
    }

    // MARK: New-audition links

    func testNewAuditionWithoutParametersIsAnEmptyForm() {
        let empty: AuditionPrefill? = prefill("auditioner://audition/new")
        XCTAssertEqual(empty, AuditionPrefill())
        XCTAssertEqual(empty?.isEmpty, true)
        XCTAssertEqual(prefill("auditioner://audition/new?"), AuditionPrefill())
    }

    func testNewAuditionWithEveryParameter() {
        let link: String = "auditioner://audition/new?orchestra=Example%20Philharmonic&position=Section%20cello"
            + "&instrument=cello&deadline=2027-01-15&auditionDate=2027-03-02"
            + "&url=https%3A%2F%2Fexample.org%2Fauditions%2Fcello"
        guard let result = prefill(link) else { return }
        XCTAssertEqual(result.orchestra, "Example Philharmonic")
        XCTAssertEqual(result.position, "Section cello")
        XCTAssertEqual(result.instrument, .cello)
        XCTAssertEqual(ymd(result.deadline), [2027, 1, 15, 12])
        XCTAssertEqual(ymd(result.auditionDate), [2027, 3, 2, 12])
        XCTAssertEqual(result.sourceURL, "https://example.org/auditions/cello")
        XCTAssertFalse(result.isEmpty)
    }

    func testParameterNamesAreCaseInsensitiveAndValuesTrimmed() {
        guard let result = prefill("auditioner://audition/new?Orchestra=%20%20Example%20Sinfonietta%0A&AUDITIONDATE=2027-03-02") else { return }
        XCTAssertEqual(result.orchestra, "Example Sinfonietta")
        XCTAssertEqual(ymd(result.auditionDate), [2027, 3, 2, 12])
    }

    func testHyphenatedInstrumentIdsAndCase() {
        XCTAssertEqual(prefill("auditioner://audition/new?instrument=double-bass")?.instrument, .doubleBass)
        XCTAssertEqual(prefill("auditioner://audition/new?instrument=Bass-Trombone")?.instrument, .bassTrombone)
    }

    func testUnknownInstrumentIsDropped() {
        XCTAssertNil(prefill("auditioner://audition/new?instrument=saxophone")?.instrument)
        XCTAssertNil(prefill("auditioner://audition/new?instrument=")?.instrument)
        XCTAssertNil(prefill("auditioner://audition/new?instrument=Cello%20section")?.instrument)
    }

    func testBadDatesAreDropped() {
        XCTAssertNil(prefill("auditioner://audition/new?deadline=2027-02-30")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?deadline=2027-13-01")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?deadline=15%2F01%2F2027")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?deadline=2027-1-5")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?deadline=2027-01-15T10:00")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?deadline=soon")?.deadline)
        XCTAssertNil(prefill("auditioner://audition/new?auditionDate=1899-12-31")?.auditionDate)
    }

    func testLeapDayIsARealDay() {
        XCTAssertEqual(ymd(prefill("auditioner://audition/new?deadline=2028-02-29")?.deadline), [2028, 2, 29, 12])
        XCTAssertNil(prefill("auditioner://audition/new?deadline=2027-02-29")?.deadline)
    }

    func testOnlyHTTPSAddressesAreKept() {
        XCTAssertEqual(prefill("auditioner://audition/new?url=https%3A%2F%2Fexample.org%2Flist")?.sourceURL, "https://example.org/list")
        XCTAssertNil(prefill("auditioner://audition/new?url=http%3A%2F%2Fexample.org%2Flist")?.sourceURL)
        XCTAssertNil(prefill("auditioner://audition/new?url=javascript%3Aalert(1)")?.sourceURL)
        XCTAssertNil(prefill("auditioner://audition/new?url=file%3A%2F%2F%2Fetc%2Fpasswd")?.sourceURL)
        XCTAssertNil(prefill("auditioner://audition/new?url=https%3A%2F%2F")?.sourceURL)
        XCTAssertNil(prefill("auditioner://audition/new?url=example.org")?.sourceURL)
    }

    func testValuesAreCappedAtTwoHundredCharacters() {
        let long: String = String(repeating: "x", count: 300)
        guard let result = prefill("auditioner://audition/new?orchestra=\(long)&position=\(long)") else { return }
        XCTAssertEqual(result.orchestra.count, 200)
        XCTAssertEqual(result.position.count, 200)
    }

    func testFirstValidValueWins() {
        guard let result = prefill("auditioner://audition/new?orchestra=First&orchestra=Second&instrument=nope&instrument=viola") else { return }
        XCTAssertEqual(result.orchestra, "First")
        XCTAssertEqual(result.instrument, .viola)
    }

    func testUnknownParametersAreIgnored() {
        guard let result = prefill("auditioner://audition/new?orchestra=Example%20Philharmonic&colour=red&notes=hello") else { return }
        XCTAssertEqual(result.orchestra, "Example Philharmonic")
        XCTAssertEqual(result.position, "")
        XCTAssertNil(result.sourceURL)
    }

    // MARK: Pieces

    func testISODayShape() {
        XCTAssertTrue(DeepLink.looksLikeISODay("2027-01-15"))
        XCTAssertFalse(DeepLink.looksLikeISODay("2027/01/15"))
        XCTAssertFalse(DeepLink.looksLikeISODay("2027-01-1"))
        XCTAssertFalse(DeepLink.looksLikeISODay("２０２７-01-15"))
        XCTAssertFalse(DeepLink.looksLikeISODay(""))
    }

    func testCleanedCollapsesLineBreaksAndEmpties() {
        XCTAssertEqual(DeepLink.cleaned("  Example\nPhilharmonic "), "Example Philharmonic")
        XCTAssertNil(DeepLink.cleaned("   "))
        XCTAssertNil(DeepLink.cleaned(nil))
    }

    // MARK: Routing

    func testExcerptInCatalogueOpensItOnTheExcerptsTab() throws {
        let router = AppRouter()
        router.selectedTab = .settings
        let catalog = CatalogStore(excerpts: [try makeExcerpt(id: "cello-quill-symphony-2-mvt2")])
        let outcome: DeepLinkRouting.Outcome = DeepLinkRouting.follow(.excerpt(id: "cello-quill-symphony-2-mvt2"),
                                                                       router: router, catalog: catalog)
        XCTAssertEqual(outcome, .followed)
        XCTAssertEqual(router.selectedTab, .excerpts)
        XCTAssertEqual(router.openedExcerptId, "cello-quill-symphony-2-mvt2")
    }

    func testUnknownExcerptGoesToTheExcerptsTabWithoutOpeningAnything() throws {
        let router = AppRouter()
        router.selectedTab = .practice
        let catalog = CatalogStore(excerpts: [try makeExcerpt(id: "cello-quill-symphony-2-mvt2")])
        let outcome: DeepLinkRouting.Outcome = DeepLinkRouting.follow(.excerpt(id: "cello-nobody-nothing"),
                                                                       router: router, catalog: catalog)
        XCTAssertEqual(outcome, .excerptMissing)
        XCTAssertEqual(router.selectedTab, .excerpts)
        XCTAssertNil(router.openedExcerptId)
    }

    func testNewAuditionLinkHandsThePrefillToTheAuditionsTab() {
        let router = AppRouter()
        let catalog = CatalogStore(excerpts: [])
        var prefill = AuditionPrefill()
        prefill.orchestra = "Example Philharmonic"
        let outcome: DeepLinkRouting.Outcome = DeepLinkRouting.follow(.newAudition(prefill), router: router, catalog: catalog)
        XCTAssertEqual(outcome, .followed)
        XCTAssertEqual(router.selectedTab, .auditions)
        XCTAssertEqual(router.auditionPrefill, prefill)
    }

    // MARK: Tutti

    func testTuttiLinkIsOffUntilTheAddressIsConfirmed() {
        XCTAssertNil(TuttiLink.findOrchestraURL)
    }

    // MARK: Beta translation pill (PLAN A7)

    func testBetaTranslationShowsOnlyOutsideEnglish() {
        XCTAssertFalse(LocalizationStatus.isBetaTranslation(preferredLocalizations: ["en"]))
        XCTAssertFalse(LocalizationStatus.isBetaTranslation(preferredLocalizations: ["en-GB", "de"]))
        XCTAssertFalse(LocalizationStatus.isBetaTranslation(preferredLocalizations: []))
        XCTAssertTrue(LocalizationStatus.isBetaTranslation(preferredLocalizations: ["de"]))
        XCTAssertTrue(LocalizationStatus.isBetaTranslation(preferredLocalizations: ["zh-Hans", "en"]))
        XCTAssertTrue(LocalizationStatus.isBetaTranslation(preferredLocalizations: ["pt-BR"]))
    }
}
