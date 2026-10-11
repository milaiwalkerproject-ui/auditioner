import XCTest
@testable import Auditioner

/// A finished mock audition counts its catalogue excerpts as practised (PLAN D6) under each
/// excerpt's own instrument, never under the player's instrument in Settings. Made-up ids.
final class MockAuditionPractisedTests: XCTestCase {

    /// Builds an excerpt the way the app does (JSON); a made-up composer and work.
    private func makeExcerpt(id: String, instrument: String) throws -> Excerpt {
        let json: String = """
        {"id": "\(id)", "instrument": "\(instrument)", "positions": ["section"], "composer": "Ada Quill",
         "work": "Symphony No. 2 in D major", "title": "Opening", "location": {"status": "unverified"},
         "sources": [], "listingStatus": "published"}
        """
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    func testExcerptsAreGroupedByTheirOwnInstrument() throws {
        let catalog = CatalogStore(excerpts: [
            try makeExcerpt(id: "cello-quill-symphony-2-mvt2", instrument: "cello"),
            try makeExcerpt(id: "cello-quill-symphony-3-mvt3", instrument: "cello"),
            try makeExcerpt(id: "viola-quill-symphony-2-mvt2", instrument: "viola"),
        ])
        let items: [MockAuditionItem] = [
            MockAuditionItem(title: "Quill · Symphony No. 2 — Opening", excerptId: "viola-quill-symphony-2-mvt2"),
            MockAuditionItem(title: "Quill · Symphony No. 3 — Opening", excerptId: "cello-quill-symphony-3-mvt3"),
            MockAuditionItem(title: "Quill · Symphony No. 2 — Opening", excerptId: "cello-quill-symphony-2-mvt2"),
            MockAuditionItem(title: "Quill · Symphony No. 2 — Opening", excerptId: "cello-quill-symphony-2-mvt2"),
        ]
        let practised: [Instrument: [String]] = MockAuditionLogic.practisedExcerpts(items) { catalog.excerpt(id: $0)?.instrument }
        XCTAssertEqual(practised, [
            .cello: ["cello-quill-symphony-2-mvt2", "cello-quill-symphony-3-mvt3"],
            .viola: ["viola-quill-symphony-2-mvt2"],
        ], "sorted, no repeats, each under its own instrument")
    }

    func testIdsNotInTheCatalogueAndTypedItemsAreSkipped() throws {
        let catalog = CatalogStore(excerpts: [try makeExcerpt(id: "cello-quill-symphony-2-mvt2", instrument: "cello")])
        let scoreId = UUID()
        let items: [MockAuditionItem] = [
            MockAuditionItem(title: "Quill · Symphony No. 2 — Opening", excerptId: "cello-quill-symphony-2-mvt2"),
            MockAuditionItem(title: "Something I typed", excerptId: nil),
            MockAuditionItem(title: "My scan", excerptId: nil, scoreId: scoreId),
            MockAuditionItem(title: "Not in this catalogue", excerptId: "horn-nobody-nothing"),
        ]
        let practised: [Instrument: [String]] = MockAuditionLogic.practisedExcerpts(items) { catalog.excerpt(id: $0)?.instrument }
        XCTAssertEqual(practised, [.cello: ["cello-quill-symphony-2-mvt2"]])
    }

    func testNothingFromTheCatalogueMeansNothingToNote() {
        let items: [MockAuditionItem] = [MockAuditionItem(title: "Something I typed")]
        XCTAssertTrue(MockAuditionLogic.practisedExcerpts(items) { _ in nil }.isEmpty)
        XCTAssertTrue(MockAuditionLogic.practisedExcerpts([]) { _ in Instrument.cello }.isEmpty)
    }
}
