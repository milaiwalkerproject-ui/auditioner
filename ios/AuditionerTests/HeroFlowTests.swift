import XCTest
@testable import Auditioner

final class HeroFlowTests: XCTestCase {

    // MARK: Fixtures

    /// Builds an excerpt the same way the app does (JSON), so the test doesn't depend on the memberwise init.
    private func makeExcerpt(id: String = "cello-brahms-symphony-2-mvt1",
                             instrument: String = "cello",
                             composer: String = "Johannes Brahms",
                             work: String = "Symphony No. 2",
                             title: String = "Opening",
                             movementNumber: Int? = nil,
                             referenceMusicXML: String? = nil,
                             soundingTransposition: Int? = nil,
                             meterJSON: String? = nil,
                             listingStatus: String = "published") throws -> Excerpt {
        var fields: [String] = [
            "\"id\": \"\(id)\"",
            "\"instrument\": \"\(instrument)\"",
            "\"positions\": [\"section\"]",
            "\"composer\": \"\(composer)\"",
            "\"work\": \"\(work)\"",
            "\"title\": \"\(title)\"",
            "\"location\": {\"status\": \"unverified\"}",
            "\"sources\": []",
            "\"listingStatus\": \"\(listingStatus)\"",
        ]
        if let movementNumber {
            fields.append("\"movement\": {\"number\": \(movementNumber)}")
        }
        if let referenceMusicXML {
            fields.append("\"referenceMusicXML\": \"\(referenceMusicXML)\"")
        }
        if let soundingTransposition {
            fields.append("\"soundingTransposition\": \(soundingTransposition)")
        }
        if let meterJSON {
            fields.append("\"meter\": \(meterJSON)")
        }
        let json = "{" + fields.joined(separator: ", ") + "}"
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    private let verifiedMeter = "{\"status\": \"verified\", \"value\": \"2/2\", \"source\": \"https://example.org/list.pdf\", \"asOf\": \"2026-10-10\"}"
    private let unverifiedMeter = "{\"status\": \"unverified\"}"

    // MARK: Which path

    func testCuratedFileWinsWhateverTheServerState() throws {
        let excerpt = try makeExcerpt(referenceMusicXML: "cello-brahms-2.musicxml")
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: excerpt, serverConfigured: true),
                       .curated(fileName: "cello-brahms-2.musicxml"))
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: excerpt, serverConfigured: false),
                       .curated(fileName: "cello-brahms-2.musicxml"))
    }

    func testBlankCuratedFileNameCountsAsMissing() throws {
        let excerpt = try makeExcerpt(referenceMusicXML: "  ")
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: excerpt, serverConfigured: true), .recognizeOnServer)
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: excerpt, serverConfigured: false), .serverNotConfigured)
    }

    func testNoExcerptGoesToServerOrToTheNotSetUpScreen() {
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: nil, serverConfigured: true), .recognizeOnServer)
        XCTAssertEqual(ScanFlowLogic.referencePath(excerpt: nil, serverConfigured: false), .serverNotConfigured)
    }

    func testServerPathFallback() {
        XCTAssertEqual(ScanFlowLogic.serverPath(serverConfigured: true), .recognizeOnServer)
        XCTAssertEqual(ScanFlowLogic.serverPath(serverConfigured: false), .serverNotConfigured)
    }

    func testConsentOnlyBeforeAnUploadAndOnlyOnce() {
        XCTAssertTrue(ScanFlowLogic.needsConsent(hasAccepted: false, path: .recognizeOnServer))
        XCTAssertFalse(ScanFlowLogic.needsConsent(hasAccepted: true, path: .recognizeOnServer))
        XCTAssertFalse(ScanFlowLogic.needsConsent(hasAccepted: false, path: .serverNotConfigured))
        XCTAssertFalse(ScanFlowLogic.needsConsent(hasAccepted: false, path: .curated(fileName: "x.musicxml")))
    }

    func testIdentificationSkippedWhenStartedFromAnExcerptPage() throws {
        XCTAssertTrue(ScanFlowLogic.needsIdentification(contextExcerpt: nil))
        XCTAssertFalse(ScanFlowLogic.needsIdentification(contextExcerpt: try makeExcerpt()))
    }

    func testPagePickerOnlyForSeveralPages() {
        XCTAssertFalse(ScanFlowLogic.needsPagePicker(pageCount: 0))
        XCTAssertFalse(ScanFlowLogic.needsPagePicker(pageCount: 1))
        XCTAssertTrue(ScanFlowLogic.needsPagePicker(pageCount: 2))
        XCTAssertTrue(ScanFlowLogic.needsPagePicker(pageCount: 40))
    }

    // MARK: Transposition

    func testDefaultTranspositionIsOctaveOnlyForTheThreeOctaveInstruments() {
        for instrument in Instrument.allCases {
            let expected: Int
            switch instrument {
            case .doubleBass, .contrabassoon: expected = -12
            case .piccolo: expected = 12
            default: expected = 0
            }
            XCTAssertEqual(ScanFlowLogic.defaultTransposition(for: instrument), expected, "\(instrument.rawValue)")
        }
    }

    func testCatalogueTranspositionWins() throws {
        let hornExcerpt = try makeExcerpt(id: "horn-x", instrument: "horn", soundingTransposition: -7)
        XCTAssertEqual(ScanFlowLogic.transposition(excerpt: hornExcerpt, fallbackInstrument: .cello), -7)
        let piccoloWithZero = try makeExcerpt(id: "piccolo-x", instrument: "piccolo", soundingTransposition: 0)
        XCTAssertEqual(ScanFlowLogic.transposition(excerpt: piccoloWithZero, fallbackInstrument: .piccolo), 0)
    }

    func testFallbackTranspositionUsesTheExcerptsInstrumentBeforeTheProfile() throws {
        let bassExcerpt = try makeExcerpt(id: "double-bass-x", instrument: "double-bass")
        XCTAssertEqual(ScanFlowLogic.transposition(excerpt: bassExcerpt, fallbackInstrument: .cello), -12)
        XCTAssertEqual(ScanFlowLogic.transposition(excerpt: nil, fallbackInstrument: .doubleBass), -12)
        XCTAssertEqual(ScanFlowLogic.transposition(excerpt: nil, fallbackInstrument: .clarinet), 0)
    }

    func testOMRInstrumentPrefersTheExcerpt() throws {
        let hornExcerpt = try makeExcerpt(id: "horn-x", instrument: "horn")
        XCTAssertEqual(ScanFlowLogic.omrInstrument(excerpt: hornExcerpt, settingsInstrument: .cello), .horn)
        XCTAssertEqual(ScanFlowLogic.omrInstrument(excerpt: nil, settingsInstrument: .viola), .viola)
    }

    // MARK: Honesty contract

    func testMeterHintOnlyWhenVerified() throws {
        XCTAssertEqual(ScanFlowLogic.meterHint(excerpt: try makeExcerpt(meterJSON: verifiedMeter)), "2/2")
        XCTAssertNil(ScanFlowLogic.meterHint(excerpt: try makeExcerpt(meterJSON: unverifiedMeter)))
        XCTAssertNil(ScanFlowLogic.meterHint(excerpt: try makeExcerpt()))
        XCTAssertNil(ScanFlowLogic.meterHint(excerpt: nil))
    }

    // MARK: Titles

    func testScoreTitleFromExcerpt() throws {
        let excerpt = try makeExcerpt()
        XCTAssertEqual(ScanFlowLogic.scoreTitle(excerpt: excerpt, date: Date()), "Brahms · Symphony No. 2 — Opening")
        let withMovement = try makeExcerpt(movementNumber: 4)
        XCTAssertEqual(ScanFlowLogic.scoreTitle(excerpt: withMovement, date: Date()), "Brahms · Symphony No. 2 — Mvt. IV · Opening")
    }

    func testScoreTitleWithoutExcerptCarriesTheDate() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let title = ScanFlowLogic.scoreTitle(excerpt: nil, date: date, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(title.hasPrefix("Scanned part "), title)
        XCTAssertGreaterThan(title.count, "Scanned part ".count)
        XCTAssertTrue(title.contains("2025"), title)
    }

    func testLibraryTitlesNameTheSource() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(ScanFlowLogic.libraryTitle(for: .camera, date: date, locale: Locale(identifier: "en_US")).hasPrefix("Scan "))
        XCTAssertTrue(ScanFlowLogic.libraryTitle(for: .photos, date: date, locale: Locale(identifier: "en_US")).hasPrefix("Photo "))
        XCTAssertTrue(ScanFlowLogic.libraryTitle(for: .files, date: date, locale: Locale(identifier: "en_US")).hasPrefix("Part "))
    }

    // MARK: Identification

    func testCandidatesRankTheMatchingExcerptFirst() throws {
        let brahms = try makeExcerpt()
        let strauss = try makeExcerpt(id: "cello-strauss-don-juan", composer: "Richard Strauss", work: "Don Juan", title: "Opening")
        let found = ScanFlowLogic.candidates(ocrLines: ["Brahms", "Symphony No. 2", "Violoncello"], pool: [strauss, brahms])
        XCTAssertEqual(found.first?.id, brahms.id)
        XCTAssertFalse(found.contains(where: { $0.id == strauss.id }))
    }

    func testCandidatesAreEmptyWithoutText() throws {
        let pool = [try makeExcerpt()]
        XCTAssertTrue(ScanFlowLogic.candidates(ocrLines: [], pool: pool).isEmpty)
        XCTAssertTrue(ScanFlowLogic.candidates(ocrLines: ["   "], pool: pool).isEmpty)
        XCTAssertTrue(ScanFlowLogic.candidates(ocrLines: ["Brahms"], pool: []).isEmpty)
    }

    func testOCRTextJoinsLines() {
        XCTAssertEqual(ScanFlowLogic.ocrText(lines: ["a", "b"]), "a b")
        XCTAssertEqual(ScanFlowLogic.ocrText(lines: []), "")
    }

    // MARK: Version string

    func testVersionString() {
        XCTAssertEqual(ScanFlowLogic.versionString(short: "0.1.0", build: "1"), "0.1.0 (1)")
        XCTAssertEqual(ScanFlowLogic.versionString(short: "0.1.0", build: nil), "0.1.0")
        XCTAssertEqual(ScanFlowLogic.versionString(short: nil, build: "7"), "(7)")
        XCTAssertEqual(ScanFlowLogic.versionString(short: " ", build: ""), "—")
    }

    // MARK: Profile options

    func testPositionsPerInstrument() {
        let base: [Position] = [.principal, .assistantPrincipal, .section, .utility, .second]
        XCTAssertEqual(ProfileOptions.positions(for: .cello), base)
        XCTAssertEqual(ProfileOptions.positions(for: .horn), base + [.high, .low])
        XCTAssertEqual(ProfileOptions.positions(for: .violin), [.concertmaster] + base)
        XCTAssertFalse(ProfileOptions.positions(for: .trumpet).contains(.high))
        XCTAssertFalse(ProfileOptions.positions(for: .viola).contains(.concertmaster))
        for instrument in Instrument.allCases {
            XCTAssertFalse(ProfileOptions.positions(for: instrument).contains(.any), instrument.rawValue)
        }
    }

    func testValidPositionFallsBackToSection() {
        XCTAssertEqual(ProfileOptions.validPosition("high", for: .horn), .high)
        XCTAssertEqual(ProfileOptions.validPosition("high", for: .cello), .section)
        XCTAssertEqual(ProfileOptions.validPosition("nonsense", for: .cello), .section)
        XCTAssertEqual(ProfileOptions.validPosition("principal", for: .flute), .principal)
    }

    func testRegionIdsMatchTheSettingsContract() {
        XCTAssertEqual(ProfileOptions.regions.map { $0.id },
                       ["north-america", "europe-german", "europe-other", "uk", "asia-pacific", "other"])
        XCTAssertEqual(ProfileOptions.defaultRegionId, "north-america")
        XCTAssertEqual(ProfileOptions.regionName(id: "uk"), "UK")
        XCTAssertEqual(ProfileOptions.regionName(id: "nope"), ProfileOptions.regions[0].name)
    }

    func testEveryInstrumentBelongsToExactlyOneFamilyGroup() {
        var seen: [Instrument] = []
        for family in Instrument.Family.allCases {
            seen.append(contentsOf: ProfileOptions.instruments(in: family))
        }
        XCTAssertEqual(seen.count, Instrument.allCases.count)
        XCTAssertEqual(Set(seen).count, Instrument.allCases.count)
    }

    func testTuningChoices() {
        XCTAssertEqual(ProfileOptions.tunings, [440, 441, 442, 443])
    }

    // MARK: Licences

    func testBundledLicenceFilesLoad() {
        let bundle = Bundle(for: CatalogStore.self)
        for file in LicenceFile.bundled {
            let text = file.text(bundle: bundle)
            XCTAssertNotNil(text, "\(file.resourceName).txt is missing from the bundle")
            XCTAssertFalse((text ?? "").isEmpty, file.resourceName)
        }
    }

    func testUniqueNotesKeepOrderAndDropRepeats() {
        let notes = ["A", "B", "A", "  ", "B", "C"]
        XCTAssertEqual(LicenceFile.uniqueNotes(notes), ["A", "B", "C"])
        XCTAssertEqual(LicenceFile.uniqueNotes([]), [])
    }

    func testNoteHeadlineIsTheFirstLineShortened() {
        XCTAssertEqual(LicenceFile.headline(of: "First line\nSecond line"), "First line")
        let long = String(repeating: "x", count: 100)
        let headline = LicenceFile.headline(of: long)
        XCTAssertEqual(headline.count, 81)
        XCTAssertTrue(headline.hasSuffix("…"))
    }
}
