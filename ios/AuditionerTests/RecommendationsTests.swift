import XCTest
@testable import Auditioner

/// PLAN D5 recommendations, on synthetic fixtures only: fictional orchestras, example.org sources,
/// no real bar numbers or dates presented as facts.
final class RecommendationsTests: XCTestCase {

    // MARK: Fixtures

    private let thisYear: Int = 2026

    private func evidence(_ source: String, year: Int?, region: String? = "north-america",
                          position: Position? = .section, orchestra: String? = "Example Orchestra") -> FrequencyEvidence {
        FrequencyEvidence(description: "Seen on an example list", orchestra: orchestra, year: year, region: region,
                          position: position, source: source, asOf: "2026-10-11")
    }

    private func excerpt(_ id: String, instrument: Instrument = .cello, evidence: [FrequencyEvidence],
                         status: ListingStatus = .published) -> Excerpt {
        Excerpt(id: id,
                instrument: instrument,
                positions: [.section],
                composer: "Example Composer",
                work: "Example Work",
                title: id,
                location: Verifiable<ExcerptLocation>.unverified,
                frequency: FrequencyInfo(tier: nil, tierStatus: nil, evidence: evidence),
                sources: [],
                listingStatus: status)
    }

    private func query(position: Position = .section, region: String? = "north-america", includeAllChairs: Bool = false,
                       includeDrafts: Bool = false) -> RecommendationQuery {
        RecommendationQuery(instrument: .cello, position: position, region: region, includeAllChairs: includeAllChairs,
                            includeDrafts: includeDrafts, currentYear: thisYear)
    }

    private func source(_ name: String) -> String {
        "https://example.org/lists/\(name).pdf"
    }

    // MARK: Weighting

    func testRecencyWeightHalvesEveryThreeYears() {
        XCTAssertEqual(LocalRecommendationEngine.weight(year: 2026, currentYear: 2026, oldestYear: nil), 1, accuracy: 1e-12)
        XCTAssertEqual(LocalRecommendationEngine.weight(year: 2023, currentYear: 2026, oldestYear: nil), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LocalRecommendationEngine.weight(year: 2020, currentYear: 2026, oldestYear: nil), 0.25, accuracy: 1e-12)
        // A list dated in the future never counts more than one from this year.
        XCTAssertEqual(LocalRecommendationEngine.weight(year: 2027, currentYear: 2026, oldestYear: nil), 1, accuracy: 1e-12)
        // No year: the oldest year present; no years at all: 1.
        XCTAssertEqual(LocalRecommendationEngine.weight(year: nil, currentYear: 2026, oldestYear: 2020), 0.25, accuracy: 1e-12)
        XCTAssertEqual(LocalRecommendationEngine.weight(year: nil, currentYear: 2026, oldestYear: nil), 1, accuracy: 1e-12)
    }

    func testShareIsRecencyWeighted() {
        let recent = evidence(source("l1"), year: 2026)
        let older = evidence(source("l2"), year: 2023)
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: [recent, older]),
            excerpt("b", evidence: [older]),
        ]
        let result = LocalRecommendationEngine.compute(excerpts: excerpts, query: query())
        XCTAssertEqual(result.totalLists, 2)
        XCTAssertEqual(result.lists.map { $0.weight }, [1, 0.5])
        let a: ExcerptAsk? = result.item(for: "a")
        let b: ExcerptAsk? = result.item(for: "b")
        XCTAssertEqual(a?.share ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(a?.listCount, 2)
        XCTAssertEqual(b?.share ?? -1, 0.5 / 1.5, accuracy: 1e-12)
        XCTAssertEqual(b?.listCount, 1)
        XCTAssertEqual(result.items.map { $0.excerptId }, ["a", "b"])
    }

    // MARK: Lists

    func testSameSourceCitedByManyExcerptsIsOneList() {
        let shared = evidence(source("one-list"), year: 2025)
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: [shared]),
            excerpt("b", evidence: [shared]),
            excerpt("c", evidence: [shared]),
        ]
        let result = LocalRecommendationEngine.compute(excerpts: excerpts, query: query())
        XCTAssertEqual(result.totalLists, 1)
        XCTAssertEqual(result.items.count, 3)
        for item in result.items {
            XCTAssertEqual(item.listCount, 1)
            XCTAssertEqual(item.share, 1, accuracy: 1e-12)
            XCTAssertNil(item.tier, "one list is not enough to name a tier")
        }
        XCTAssertEqual(result.lists.first?.orchestra, "Example Orchestra")
        XCTAssertEqual(result.lists.first?.source, source("one-list"))
    }

    func testSameSourceInDifferentYearsIsTwoLists() {
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: [evidence(source("page"), year: 2024), evidence(source("page"), year: 2026)]),
        ]
        let result = LocalRecommendationEngine.compute(excerpts: excerpts, query: query())
        XCTAssertEqual(result.totalLists, 2)
        XCTAssertEqual(result.lists.map { $0.year }, [2026, 2024], "newest first")
        XCTAssertEqual(result.item(for: "a")?.listCount, 2)
    }

    func testRowsWithoutSourceAreSkippedAndDraftsOnlyInReviewerMode() {
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: [evidence("   ", year: 2026)]),
            excerpt("draft", evidence: [evidence(source("d"), year: 2026)], status: .draft),
            excerpt("viola", instrument: .viola, evidence: [evidence(source("v"), year: 2026)]),
        ]
        let plain = LocalRecommendationEngine.compute(excerpts: excerpts, query: query())
        XCTAssertEqual(plain.totalLists, 0)
        XCTAssertTrue(plain.items.isEmpty)
        let reviewer = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(includeDrafts: true))
        XCTAssertEqual(reviewer.totalLists, 1)
        XCTAssertEqual(reviewer.items.map { $0.excerptId }, ["draft"])
    }

    // MARK: Tiers

    func testTierThresholds() {
        XCTAssertEqual(LocalRecommendationEngine.tier(share: 0.5, totalLists: 5), .core)
        XCTAssertEqual(LocalRecommendationEngine.tier(share: 0.49, totalLists: 5), .common)
        XCTAssertEqual(LocalRecommendationEngine.tier(share: 0.2, totalLists: 5), .common)
        XCTAssertEqual(LocalRecommendationEngine.tier(share: 0.19, totalLists: 5), .occasional)
        XCTAssertNil(LocalRecommendationEngine.tier(share: 0.9, totalLists: 4), "fewer than 5 lists: no tier")
        XCTAssertNil(LocalRecommendationEngine.tier(share: 1, totalLists: 0))
    }

    func testTiersNeedFiveLists() {
        let lists: [FrequencyEvidence] = (1...10).map { evidence(source("l\($0)"), year: 2026) }
        let excerpts: [Excerpt] = [
            excerpt("core", evidence: Array(lists[0..<5])),
            excerpt("common", evidence: Array(lists[0..<2])),
            excerpt("occasional", evidence: [lists[0]]),
            excerpt("filler", evidence: lists),
        ]
        let result = LocalRecommendationEngine.compute(excerpts: excerpts, query: query())
        XCTAssertEqual(result.totalLists, 10)
        XCTAssertTrue(result.hasEnoughLists)
        XCTAssertEqual(result.item(for: "core")?.tier, .core)
        XCTAssertEqual(result.item(for: "core")?.share ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.item(for: "common")?.tier, .common)
        XCTAssertEqual(result.item(for: "occasional")?.tier, .occasional)
        XCTAssertEqual(result.items.first?.excerptId, "filler")
        XCTAssertNil(LocalRecommendationEngine.notEnoughListsNote(totalLists: 10))

        let few: [Excerpt] = [excerpt("x", evidence: Array(lists[0..<4]))]
        let fewResult = LocalRecommendationEngine.compute(excerpts: few, query: query())
        XCTAssertEqual(fewResult.totalLists, 4)
        XCTAssertFalse(fewResult.hasEnoughLists)
        XCTAssertNil(fewResult.item(for: "x")?.tier)
        XCTAssertEqual(fewResult.item(for: "x")?.share ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(LocalRecommendationEngine.notEnoughListsNote(totalLists: 4),
                       "Not enough lists yet to name a tier — we have 4, we need 5.")
        XCTAssertNil(LocalRecommendationEngine.notEnoughListsNote(totalLists: 0))
    }

    // MARK: Chairs

    func testMatchesChair() {
        XCTAssertTrue(LocalRecommendationEngine.matchesChair(.section, wanted: .section, includeAllChairs: false))
        XCTAssertTrue(LocalRecommendationEngine.matchesChair(.any, wanted: .section, includeAllChairs: false))
        XCTAssertFalse(LocalRecommendationEngine.matchesChair(.principal, wanted: .section, includeAllChairs: false))
        XCTAssertFalse(LocalRecommendationEngine.matchesChair(.assistantPrincipal, wanted: .principal, includeAllChairs: false))
        XCTAssertFalse(LocalRecommendationEngine.matchesChair(nil, wanted: .section, includeAllChairs: false))
        XCTAssertTrue(LocalRecommendationEngine.matchesChair(nil, wanted: .section, includeAllChairs: true))
        XCTAssertTrue(LocalRecommendationEngine.matchesChair(.principal, wanted: .section, includeAllChairs: true))
        XCTAssertTrue(LocalRecommendationEngine.matchesChair(.principal, wanted: .any, includeAllChairs: false))
    }

    func testPositionFilteringAndIncludeAllChairs() {
        let rows: [FrequencyEvidence] = [
            evidence(source("section"), year: 2026, position: .section),
            evidence(source("any"), year: 2026, position: .any),
            evidence(source("principal"), year: 2026, position: .principal),
            evidence(source("unknown-chair"), year: 2026, position: nil),
        ]
        let excerpts: [Excerpt] = [excerpt("a", evidence: rows)]

        let section = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(position: .section))
        XCTAssertEqual(section.totalLists, 2)
        XCTAssertEqual(Set(section.lists.map { $0.source }), [source("section"), source("any")])
        XCTAssertEqual(section.listsWithoutChair, 1)
        XCTAssertTrue(section.notes.contains("1 more list doesn't say which chair it was for. Turn on Include all chairs to count it."))

        let principal = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(position: .principal))
        XCTAssertEqual(Set(principal.lists.map { $0.source }), [source("principal"), source("any")])

        let all = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(includeAllChairs: true))
        XCTAssertEqual(all.totalLists, 4)
        XCTAssertEqual(all.listsWithoutChair, 0)
        XCTAssertFalse(all.notes.contains { $0.contains("Include all chairs") })
        XCTAssertEqual(all.item(for: "a")?.evidence, "On 4 of the 4 cello lists we've collected, all chairs (2026)")
    }

    // MARK: Regions

    func testRegionFallbackWhenTooFewListsAtHome() {
        var rows: [FrequencyEvidence] = (1...6).map { evidence(source("na\($0)"), year: 2026, region: "north-america") }
        rows.append(evidence(source("uk1"), year: 2026, region: "uk"))
        let excerpts: [Excerpt] = [excerpt("a", evidence: rows)]

        let uk = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(region: "uk"))
        XCTAssertTrue(uk.fellBackToAllRegions)
        XCTAssertEqual(uk.totalLists, 7)
        XCTAssertEqual(uk.notes.first, "Fewer than 5 section cello lists from UK so far, so this counts lists from every region.")

        let home = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(region: "north-america"))
        XCTAssertFalse(home.fellBackToAllRegions)
        XCTAssertEqual(home.totalLists, 6)
        XCTAssertEqual(home.notes.first, "Counting lists from North America.")

        let everywhere = LocalRecommendationEngine.compute(excerpts: excerpts, query: query(region: nil))
        XCTAssertFalse(everywhere.fellBackToAllRegions)
        XCTAssertEqual(everywhere.totalLists, 7)
        XCTAssertEqual(everywhere.notes.first, "Counting lists from every region.")
    }

    func testNoFallbackWithFiveListsAtHome() {
        var rows: [FrequencyEvidence] = (1...5).map { evidence(source("uk\($0)"), year: 2026, region: "uk") }
        rows.append(evidence(source("na1"), year: 2026, region: "north-america"))
        rows.append(evidence(source("na2"), year: 2026, region: "north-america"))
        let result = LocalRecommendationEngine.compute(excerpts: [excerpt("a", evidence: rows)], query: query(region: "uk"))
        XCTAssertFalse(result.fellBackToAllRegions)
        XCTAssertEqual(result.totalLists, 5)
        XCTAssertTrue(result.hasEnoughLists)
    }

    func testNoFallbackWhenOtherRegionsAddNothing() {
        let rows: [FrequencyEvidence] = [evidence(source("uk1"), year: 2026, region: "uk")]
        let result = LocalRecommendationEngine.compute(excerpts: [excerpt("a", evidence: rows)], query: query(region: "uk"))
        XCTAssertFalse(result.fellBackToAllRegions)
        XCTAssertEqual(result.totalLists, 1)
    }

    // MARK: Undated lists

    func testUndatedListsCountAsTheOldestYear() {
        let rows: [FrequencyEvidence] = [
            evidence(source("new"), year: 2026),
            evidence(source("old"), year: 2020),
            evidence(source("undated"), year: nil),
        ]
        let result = LocalRecommendationEngine.compute(excerpts: [excerpt("a", evidence: rows)], query: query())
        XCTAssertEqual(result.undatedLists, 1)
        XCTAssertEqual(result.oldestYear, 2020)
        XCTAssertEqual(result.lists.map { $0.source }, [source("new"), source("old"), source("undated")], "undated last")
        XCTAssertEqual(result.lists[2].weight, 0.25, accuracy: 1e-12)
        XCTAssertEqual(result.yearSpan, 2020...2026)
        XCTAssertTrue(result.notes.contains("1 of these lists has no date and counts as the oldest year we have (2020)."))
    }

    func testAllUndatedListsCountTheSame() {
        let rows: [FrequencyEvidence] = [evidence(source("x"), year: nil), evidence(source("y"), year: nil)]
        let result = LocalRecommendationEngine.compute(excerpts: [excerpt("a", evidence: rows)], query: query())
        XCTAssertEqual(result.undatedLists, 2)
        XCTAssertNil(result.oldestYear)
        XCTAssertNil(result.yearSpan)
        XCTAssertEqual(result.lists.map { $0.weight }, [1, 1])
        XCTAssertTrue(result.notes.contains("None of these lists has a date, so they all count the same."))
        XCTAssertEqual(result.item(for: "a")?.evidence, "On 2 of the 2 section cello lists we've collected")
    }

    // MARK: Words

    func testEvidenceText() {
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 7, totalLists: 9, instrument: .cello, position: .section,
                                                              includeAllChairs: false, years: 2022...2026),
                       "On 7 of the 9 section cello lists we've collected (2022\u{2013}2026)")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 1, totalLists: 1, instrument: .cello, position: .section,
                                                              includeAllChairs: false, years: 2025...2025),
                       "On the only section cello list we've collected (2025)")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 0, totalLists: 9, instrument: .cello, position: .section,
                                                              includeAllChairs: false, years: 2022...2026),
                       "Not on any of the 9 section cello lists we've collected (2022\u{2013}2026)")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 0, totalLists: 1, instrument: .horn, position: .principal,
                                                              includeAllChairs: false, years: 2025...2025),
                       "Not on the only principal horn list we've collected (2025)")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 0, totalLists: 0, instrument: .cello, position: .assistantPrincipal,
                                                              includeAllChairs: false, years: nil),
                       "We haven't collected any assistant principal cello lists yet.")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 3, totalLists: 4, instrument: .cello, position: .section,
                                                              includeAllChairs: true, years: 2024...2026),
                       "On 3 of the 4 cello lists we've collected, all chairs (2024\u{2013}2026)")
        XCTAssertEqual(LocalRecommendationEngine.evidenceText(listCount: 2, totalLists: 3, instrument: .doubleBass, position: .section,
                                                              includeAllChairs: false, years: nil),
                       "On 2 of the 3 section double bass lists we've collected")
    }

    func testInstrumentWords() {
        XCTAssertEqual(LocalRecommendationEngine.instrumentWords(.cello), "cello")
        XCTAssertEqual(LocalRecommendationEngine.instrumentWords(.doubleBass), "double bass")
        XCTAssertEqual(LocalRecommendationEngine.instrumentWords(.eFlatClarinet), "E♭ clarinet")
        XCTAssertEqual(LocalRecommendationEngine.listsPhrase(count: 1, instrument: .horn, position: .high, includeAllChairs: false), "high horn list")
        XCTAssertEqual(LocalRecommendationEngine.listsPhrase(count: 3, instrument: .trumpet, position: .second, includeAllChairs: true), "trumpet lists")
    }

    func testAskForExcerptOnNoList() {
        let rows: [FrequencyEvidence] = (1...3).map { evidence(source("l\($0)"), year: 2026) }
        let result = LocalRecommendationEngine.compute(excerpts: [excerpt("a", evidence: rows)], query: query())
        let ask = result.ask(for: "not-cited")
        XCTAssertEqual(ask.listCount, 0)
        XCTAssertEqual(ask.totalLists, 3)
        XCTAssertNil(ask.tier)
        XCTAssertEqual(ask.evidence, "Not on any of the 3 section cello lists we've collected (2026)")
        XCTAssertEqual(result.ask(for: "a").listCount, 3)
    }

    // MARK: Server merge

    private func serverRow(_ id: String, tier: String, share: Double, listCount: Int, totalLists: Int, openNow: Int) -> Recommendation {
        Recommendation(excerptId: id, tier: tier, share: share, listCount: listCount, totalLists: totalLists, openNow: openNow,
                       evidence: "On \(listCount) of \(totalLists) section cello lists in an example region")
    }

    func testServerTierFollowsTheFiveListRule() {
        XCTAssertEqual(RecommendationMerge.serverTier("core", totalLists: 5), .core)
        XCTAssertEqual(RecommendationMerge.serverTier(" Common ", totalLists: 12), .common)
        XCTAssertEqual(RecommendationMerge.serverTier("occasional", totalLists: 40), .occasional)
        XCTAssertNil(RecommendationMerge.serverTier("core", totalLists: 4))
        XCTAssertNil(RecommendationMerge.serverTier("legendary", totalLists: 40))
    }

    func testServerItemsAreOrderedAndCleaned() {
        let rows: [Recommendation] = [
            serverRow("b", tier: "common", share: 0.3, listCount: 3, totalLists: 10, openNow: 0),
            serverRow("a", tier: "core", share: 0.7, listCount: 7, totalLists: 10, openNow: 2),
            serverRow("a", tier: "core", share: 0.7, listCount: 7, totalLists: 10, openNow: 9),
            serverRow("", tier: "core", share: 0.9, listCount: 9, totalLists: 10, openNow: 0),
            serverRow("c", tier: "core", share: 1.4, listCount: 3, totalLists: 3, openNow: -1),
        ]
        let items = RecommendationMerge.items(fromServer: rows)
        XCTAssertEqual(items.map { $0.excerptId }, ["c", "a", "b"])
        XCTAssertEqual(items[0].share, 1, "share is clamped to 0…1")
        XCTAssertNil(items[0].tier, "3 lists: no tier even if the server named one")
        XCTAssertEqual(items[0].openNow, 0)
        XCTAssertEqual(items[1].tier, .core)
        XCTAssertEqual(items[1].openNow, 2, "the first row for an id wins")
        XCTAssertEqual(items[2].source, .server)
        XCTAssertEqual(RecommendationMerge.openNow(from: rows), ["a": 9])
    }

    func testTopKeepsOnlyExcerptsThatWereAsked() {
        let local = LocalRecommendationEngine.compute(
            excerpts: [
                excerpt("a", evidence: [evidence(source("l1"), year: 2026), evidence(source("l2"), year: 2026)]),
                excerpt("b", evidence: [evidence(source("l1"), year: 2026)]),
            ],
            query: query())
        var items: [RecommendationItem] = RecommendationMerge.items(fromLocal: local)
        items.append(RecommendationItem(excerptId: "never", share: 0, listCount: 0, totalLists: 2, tier: nil,
                                        evidence: "Not on any list", openNow: nil, source: .catalogue))
        XCTAssertEqual(RecommendationMerge.top(items, limit: 5).map { $0.excerptId }, ["a", "b"])
        XCTAssertEqual(RecommendationMerge.top(items, limit: 1).map { $0.excerptId }, ["a"])
        XCTAssertTrue(RecommendationMerge.top(items, limit: 0).isEmpty)
        XCTAssertNil(items[0].openNow)
        let withOpen = RecommendationMerge.applyingOpenNow(items, openNow: ["a": 3])
        XCTAssertEqual(withOpen[0].openNow, 3)
        XCTAssertEqual(withOpen[1].openNow, 0)
        XCTAssertNil(RecommendationMerge.applyingOpenNow(items, openNow: nil)[0].openNow)
    }

    func testOpenNowTextAndNotes() {
        XCTAssertEqual(RecommendationMerge.openNowText(1), "On 1 open audition now")
        XCTAssertEqual(RecommendationMerge.openNowText(3), "On 3 open auditions now")
        XCTAssertNil(RecommendationMerge.fallbackNote(for: APIError.notConfigured))
        XCTAssertEqual(RecommendationMerge.fallbackNote(for: APIError.server(status: 503, message: "")),
                       "Couldn't reach our server, so this uses the lists in the app's catalogue.")
        XCTAssertEqual(RecommendationMerge.fallbackNote(for: URLError(.notConnectedToInternet)),
                       "Couldn't reach our server, so this uses the lists in the app's catalogue.")
        XCTAssertEqual(RecommendationSource.server.label, "From orchestra lists on our server")
        XCTAssertEqual(RecommendationSource.catalogue.label, "From the lists in the app's catalogue")
    }

    // MARK: Browser section

    func testMostAskedSectionShowsOnlyOnThePlainList() {
        XCTAssertTrue(ExcerptBrowserLogic.showsMostAsked(query: "", isFiltering: false))
        XCTAssertTrue(ExcerptBrowserLogic.showsMostAsked(query: "   ", isFiltering: false))
        XCTAssertFalse(ExcerptBrowserLogic.showsMostAsked(query: "Example", isFiltering: false))
        XCTAssertFalse(ExcerptBrowserLogic.showsMostAsked(query: "", isFiltering: true))
    }

    func testMostAskedKeepsOnlyExcerptsOnThisDevice() {
        let items: [RecommendationItem] = ["a", "b", "c", "d", "e", "f", "missing"].enumerated().map { index, id in
            RecommendationItem(excerptId: id, share: 1.0 - Double(index) * 0.1, listCount: 7 - index, totalLists: 10,
                               tier: .core, evidence: "", openNow: 0, source: .server)
        }
        let pool: [Excerpt] = ["a", "b", "c", "d", "e", "f"].map { excerpt($0, evidence: []) }
        let entries = ExcerptBrowserLogic.mostAsked(items, in: pool)
        XCTAssertEqual(entries.map { $0.id }, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(entries.first?.item.share ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(ExcerptBrowserLogic.mostAsked(items, in: pool, limit: 2).count, 2)
        XCTAssertTrue(ExcerptBrowserLogic.mostAsked(items, in: []).isEmpty)
    }

    // MARK: Service

    @MainActor
    func testServiceUsesTheCatalogueWithoutAServer() async {
        let service = RecommendationService()
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: [evidence(source("l1"), year: 2026), evidence(source("l2"), year: 2025)]),
            excerpt("b", evidence: [evidence(source("l2"), year: 2025)]),
        ]
        let client = APIClient(baseURL: nil, deviceId: "test-device")
        await service.refresh(excerpts: excerpts, query: query(), client: client)
        XCTAssertEqual(service.source, .catalogue)
        XCTAssertEqual(service.items.map { $0.excerptId }, ["a", "b"])
        XCTAssertEqual(service.instrument, .cello)
        XCTAssertNil(service.openNow)
        XCTAssertNil(service.serverNote)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.openNowCount(for: "a", instrument: .cello), "no server answer: the badge stays hidden")
        XCTAssertEqual(service.local?.totalLists, 2)
        XCTAssertEqual(service.item(for: "b")?.listCount, 1)
    }

    func testAskSummaryForOneExcerpt() {
        let excerpts: [Excerpt] = [
            excerpt("a", evidence: (1...6).map { evidence(source("l\($0)"), year: 2026) }),
            excerpt("b", evidence: [evidence(source("l1"), year: 2026)]),
        ]
        let summary = ExcerptAskSummary.make(excerptId: "b", catalogExcerpts: excerpts, query: query(), openNow: 2)
        XCTAssertEqual(summary.ask.listCount, 1)
        XCTAssertEqual(summary.ask.totalLists, 6)
        XCTAssertEqual(summary.tier, .occasional)
        XCTAssertEqual(summary.openNow, 2)
        XCTAssertNil(summary.notEnoughListsNote)
        XCTAssertEqual(summary.notes.first, "Counting lists from North America.")
        XCTAssertEqual(summary.sourceLabel, "From the lists in the app's catalogue")

        let unlisted = ExcerptAskSummary.make(excerptId: "zzz", catalogExcerpts: excerpts, query: query(), openNow: nil)
        XCTAssertEqual(unlisted.ask.evidence, "Not on any of the 6 section cello lists we've collected (2026)")
        XCTAssertNil(unlisted.openNow)
    }

    func testSettingsQuery() {
        let now: Date = Date(timeIntervalSince1970: 1_790_000_000) // 2026
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let q = RecommendationSettings.query(instrument: .horn, positionRaw: "high", region: " uk ", includeAllChairs: true,
                                             includeDrafts: false, now: now, calendar: calendar)
        XCTAssertEqual(q.instrument, .horn)
        XCTAssertEqual(q.position, .high)
        XCTAssertEqual(q.region, "uk")
        XCTAssertTrue(q.includeAllChairs)
        XCTAssertEqual(q.currentYear, calendar.component(.year, from: now))
        let blank = RecommendationSettings.query(instrument: .cello, positionRaw: "nonsense", region: "", includeAllChairs: false,
                                                 includeDrafts: true, now: now, calendar: calendar)
        XCTAssertEqual(blank.position, .section)
        XCTAssertNil(blank.region)
        XCTAssertTrue(blank.includeDrafts)
    }

    // MARK: Include all chairs, per instrument (PLAN F5)

    func testIncludeAllChairsDefaultsOnForBrassOnly() {
        for instrument in Instrument.allCases {
            XCTAssertEqual(RecommendationSettings.defaultIncludeAllChairs(for: instrument), instrument.family == .brass, instrument.rawValue)
        }
        XCTAssertTrue(RecommendationSettings.defaultIncludeAllChairs(for: .horn))
        XCTAssertTrue(RecommendationSettings.defaultIncludeAllChairs(for: .trumpet))
        XCTAssertTrue(RecommendationSettings.defaultIncludeAllChairs(for: .trombone))
        XCTAssertTrue(RecommendationSettings.defaultIncludeAllChairs(for: .bassTrombone))
        XCTAssertTrue(RecommendationSettings.defaultIncludeAllChairs(for: .tuba))
        XCTAssertFalse(RecommendationSettings.defaultIncludeAllChairs(for: .cello))
        XCTAssertFalse(RecommendationSettings.defaultIncludeAllChairs(for: .flute))
        XCTAssertFalse(RecommendationSettings.defaultIncludeAllChairs(for: .timpani))
        XCTAssertFalse(RecommendationSettings.defaultIncludeAllChairs(for: .keyboard))
        XCTAssertEqual(RecommendationSettings.includeAllChairsKey(for: .bassTrombone), "recommendations.includeAllChairs.bass-trombone")
        XCTAssertEqual(RecommendationSettings.includeAllChairsKey(for: .cello), "recommendations.includeAllChairs.cello")
    }

    func testIncludeAllChairsIsRememberedPerInstrument() {
        let suiteName: String = "RecommendationsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("no defaults suite") }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(RecommendationSettings.includeAllChairs(for: .horn, defaults: defaults), "brass: on until the player says otherwise")
        XCTAssertFalse(RecommendationSettings.includeAllChairs(for: .cello, defaults: defaults))

        RecommendationSettings.setIncludeAllChairs(true, for: .cello, defaults: defaults)
        RecommendationSettings.setIncludeAllChairs(false, for: .horn, defaults: defaults)
        XCTAssertTrue(RecommendationSettings.includeAllChairs(for: .cello, defaults: defaults))
        XCTAssertFalse(RecommendationSettings.includeAllChairs(for: .horn, defaults: defaults), "the player's choice beats the brass default")
        XCTAssertTrue(RecommendationSettings.includeAllChairs(for: .trumpet, defaults: defaults), "other brass keep their default")
        XCTAssertFalse(RecommendationSettings.includeAllChairs(for: .viola, defaults: defaults), "other instruments keep theirs")

        // The old, instrument-less key from before PLAN F5 is not read.
        defaults.set(true, forKey: "recommendations.includeAllChairs")
        XCTAssertFalse(RecommendationSettings.includeAllChairs(for: .viola, defaults: defaults))
    }

    @MainActor
    func testIncludeAllChairsStoreWritesThroughAndAnnouncesChanges() {
        let suiteName: String = "RecommendationsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("no defaults suite") }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = IncludeAllChairsStore(defaults: defaults)
        XCTAssertTrue(store.includeAllChairs(for: .tuba))
        XCTAssertEqual(store.changeCount, 0)
        let binding = store.binding(for: .tuba)
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(store.includeAllChairs(for: .tuba))
        XCTAssertFalse(RecommendationSettings.includeAllChairs(for: .tuba, defaults: defaults))
        XCTAssertEqual(store.changeCount, 1)
        XCTAssertTrue(store.includeAllChairs(for: .horn), "one instrument's choice doesn't touch another's")
    }

    func testInfoSheetCopyNamesTheRules() {
        let paragraphs = RecommendationInfoCopy.paragraphs
        XCTAssertEqual(paragraphs.count, 8)
        XCTAssertEqual(Set(paragraphs.map { $0.id }).count, paragraphs.count)
        XCTAssertTrue(paragraphs.contains { $0.text.contains("at least 5 lists") })
        XCTAssertTrue(paragraphs.contains { $0.text.contains("three years ago as a half") })
        XCTAssertTrue(paragraphs.contains { $0.text.contains("never changes the share") })
    }
}
