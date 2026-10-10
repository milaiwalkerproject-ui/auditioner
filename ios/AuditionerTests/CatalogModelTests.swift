import XCTest
@testable import Auditioner

final class CatalogModelTests: XCTestCase {
    func testVerifiableHidesUnverifiedValue() throws {
        let json = #"{"status":"unverified","source":"https://example.org/list.pdf"}"#
        let v = try JSONDecoder().decode(Verifiable<String>.self, from: Data(json.utf8))
        XCTAssertNil(v.verifiedValue)
        XCTAssertEqual(v.sourceURL?.host, "example.org")
    }

    func testVerifiedValueIsShown() throws {
        let json = #"{"status":"verified","value":"Allegro","source":"https://example.org","asOf":"2026-10-10"}"#
        let v = try JSONDecoder().decode(Verifiable<String>.self, from: Data(json.utf8))
        XCTAssertEqual(v.verifiedValue, "Allegro")
    }

    func testRomanNumerals() {
        XCTAssertEqual(Excerpt.roman(1), "I")
        XCTAssertEqual(Excerpt.roman(4), "IV")
        XCTAssertEqual(Excerpt.roman(9), "IX")
        XCTAssertEqual(Excerpt.roman(14), "XIV")
    }

    func testBundledCatalogueDecodes() {
        let store = CatalogStore(bundle: Bundle(for: CatalogStore.self))
        XCTAssertTrue(store.loadErrors.isEmpty, "Catalogue decode errors: \(store.loadErrors)")
    }

    func testDemoScaleIsBundled() {
        let doc = ScoreDocument.bundled(named: "demo-d-major-scale.musicxml", title: "Demo", origin: .demo,
                                        instrument: .cello, bundle: Bundle(for: CatalogStore.self))
        XCTAssertNotNil(doc)
    }
}
