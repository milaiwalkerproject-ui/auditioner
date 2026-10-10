import XCTest
import SwiftData
@testable import Auditioner

final class ExcerptsMediaTests: XCTestCase {
    // MARK: Fixtures

    private func makeExcerpt(id: String, composer: String, work: String, title: String = "Opening",
                             positions: [Position] = [.section], movement: Int? = nil,
                             tier: FrequencyTier? = nil, tierStatus: FactStatus? = nil) -> Excerpt {
        Excerpt(id: id,
                instrument: .cello,
                positions: positions,
                composer: composer,
                work: work,
                movement: movement.map { Movement(number: $0, title: nil) },
                title: title,
                location: Verifiable<ExcerptLocation>.unverified,
                frequency: FrequencyInfo(tier: tier, tierStatus: tierStatus, evidence: nil),
                sources: [],
                listingStatus: .published)
    }

    // MARK: YouTube player page

    func testPlayerHTMLContainsRequiredPieces() {
        let html = YouTubePlayerHTML.build(videoId: "abc_DEF-123", startSeconds: 82, endSeconds: 150,
                                           origin: "https://com.milaiwalker.auditioner")
        XCTAssertTrue(html.contains("https://www.youtube-nocookie.com"))
        XCTAssertTrue(html.contains("https://www.youtube.com/iframe_api"))
        XCTAssertTrue(html.contains("start: 82"))
        XCTAssertTrue(html.contains("end: 150"))
        XCTAssertTrue(html.contains("playsinline: 1"))
        XCTAssertTrue(html.contains("rel: 0"))
        XCTAssertTrue(html.contains("videoId: 'abc_DEF-123'"))
        XCTAssertTrue(html.contains("origin: 'https://com.milaiwalker.auditioner'"))
        XCTAssertTrue(html.contains("messageHandlers.auditionerPlayer.postMessage"))
        XCTAssertFalse(html.lowercased().contains("autoplay"))
    }

    func testPlayerHTMLOmitsUnknownTimes() {
        let html = YouTubePlayerHTML.build(videoId: "abc", startSeconds: nil, endSeconds: nil, origin: "https://x")
        XCTAssertFalse(html.contains("start:"))
        XCTAssertFalse(html.contains("end:"))
    }

    func testVideoIdIsSanitised() {
        XCTAssertEqual(YouTubePlayerHTML.sanitizedVideoId("ab'c\"<d>e f"), "abcdef")
        let html = YouTubePlayerHTML.build(videoId: "x'); alert(1); ('", startSeconds: nil, endSeconds: nil, origin: "https://x")
        XCTAssertFalse(html.contains("alert(1)"))
    }

    func testOriginUsesLowercasedBundleId() {
        XCTAssertEqual(YouTubePlayerHTML.origin(bundleIdentifier: "Com.MilaiWalker.Auditioner"), "https://com.milaiwalker.auditioner")
        XCTAssertEqual(YouTubePlayerHTML.origin(bundleIdentifier: nil), "https://com.milaiwalker.auditioner")
    }

    func testNavigationPolicy() throws {
        let base = try XCTUnwrap(URL(string: "https://com.milaiwalker.auditioner"))
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: base, isLinkActivated: false, isMainFrame: true,
                                                      hasTargetFrame: true, baseHost: base.host), .allow)

        let embed = try XCTUnwrap(URL(string: "https://www.youtube-nocookie.com/embed/abc?enablejsapi=1"))
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: embed, isLinkActivated: false, isMainFrame: false,
                                                      hasTargetFrame: true, baseHost: base.host), .allow)

        let tapped = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc"))
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: tapped, isLinkActivated: true, isMainFrame: true,
                                                      hasTargetFrame: true, baseHost: base.host), .openExternally)
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: tapped, isLinkActivated: false, isMainFrame: false,
                                                      hasTargetFrame: false, baseHost: base.host), .openExternally)
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: tapped, isLinkActivated: false, isMainFrame: true,
                                                      hasTargetFrame: true, baseHost: base.host), .block)

        let other = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: other, isLinkActivated: false, isMainFrame: false,
                                                      hasTargetFrame: true, baseHost: base.host), .block)

        let blank = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertEqual(YouTubeNavigationPolicy.decide(url: blank, isLinkActivated: false, isMainFrame: true,
                                                      hasTargetFrame: true, baseHost: base.host), .allow)

        XCTAssertTrue(YouTubeNavigationPolicy.isAllowedFrameHost("s.ytimg.com"))
        XCTAssertFalse(YouTubeNavigationPolicy.isAllowedFrameHost("notyoutube.com"))
    }

    func testPlayerControllerReadsMessages() {
        let controller = YouTubePlayerController()
        controller.handle(messageBody: ["type": "ready", "rates": [0.5, 1.0, 1.5]] as [String: Any])
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(controller.availableRates, [0.5, 1.0, 1.5])
        controller.handle(messageBody: ["type": "time", "t": 83.4] as [String: Any])
        XCTAssertEqual(controller.currentTime, 83.4, accuracy: 0.001)
        controller.handle(messageBody: ["type": "state", "state": 1] as [String: Any])
        XCTAssertTrue(controller.isPlaying)
        XCTAssertTrue(controller.hasPlayed)
        controller.handle(messageBody: ["type": "error", "code": 150] as [String: Any])
        XCTAssertEqual(controller.errorCode, 150)
        controller.handle(messageBody: "not a dictionary")
        XCTAssertEqual(controller.errorCode, 150)
    }

    // MARK: Time formatting

    func testTimeFormatting() {
        XCTAssertEqual(MediaTimeFormatter.mmss(0), "0:00")
        XCTAssertEqual(MediaTimeFormatter.mmss(83), "1:23")
        XCTAssertEqual(MediaTimeFormatter.mmss(59.9), "0:59")
        XCTAssertEqual(MediaTimeFormatter.mmss(600), "10:00")
        XCTAssertEqual(MediaTimeFormatter.mmss(3725), "1:02:05")
        XCTAssertEqual(MediaTimeFormatter.mmss(-5), "0:00")
        XCTAssertEqual(MediaTimeFormatter.mmss(Double.nan), "0:00")
        XCTAssertEqual(MediaTimeFormatter.wholeSeconds(82.9), 82)
        XCTAssertEqual(MediaTimeFormatter.youtubeCueSecond(verifiedStart: 83), 82)
        XCTAssertEqual(MediaTimeFormatter.youtubeCueSecond(verifiedStart: 0.5), 0)
    }

    // MARK: Tempo symbols

    func testTempoSymbols() {
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "quarter"), "\u{2669}")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "dotted-quarter"), "\u{2669}.")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "half"), "\u{1D15E}")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "dotted-half"), "\u{1D15E}.")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "eighth"), "\u{266A}")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "dotted-eighth"), "\u{266A}.")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "whole"), "\u{1D15D}")
        XCTAssertEqual(TempoSymbols.symbol(forBeatUnit: "sixteenth"), "\u{1D161}")
        XCTAssertEqual(TempoSymbols.text(for: TempoRange(beatUnit: "quarter", bpmMin: 88, bpmMax: 96)), "\u{2669} = 88\u{2013}96")
        XCTAssertEqual(TempoSymbols.text(for: TempoRange(beatUnit: "quarter", bpmMin: 88, bpmMax: 88)), "\u{2669} = 88")
        XCTAssertEqual(TempoSymbols.text(for: TempoRange(beatUnit: "dotted-quarter", bpmMin: 60, bpmMax: 66)), "\u{2669}. = 60\u{2013}66")
        XCTAssertEqual(TempoSymbols.bpmText(72.5), "72.5")
    }

    // MARK: Text helpers

    func testHumanizeTechnique() {
        XCTAssertEqual(ExcerptFormat.humanizeTechnique("sustained-legato"), "Sustained legato")
        XCTAssertEqual(ExcerptFormat.humanizeTechnique("intonation"), "Intonation")
        XCTAssertEqual(ExcerptFormat.humanizeTechnique("string-crossings"), "String crossings")
    }

    func testSurnameAndSortKey() {
        XCTAssertEqual(ExcerptFormat.surname("Ludwig van Beethoven"), "Beethoven")
        XCTAssertEqual(ExcerptFormat.surname("Strauss"), "Strauss")
        XCTAssertEqual(ExcerptFormat.sortKey("Bartók"), "bartok")
    }

    func testHostLabel() {
        XCTAssertEqual(ExcerptFormat.hostLabel("https://www.aso.org/assets/doc/list.pdf"), "aso.org")
        XCTAssertEqual(ExcerptFormat.hostLabel("https://cso.org/media/x.pdf"), "cso.org")
        XCTAssertEqual(ExcerptFormat.hostLabel("not a url"), "not a url")
    }

    func testCopyrightLines() {
        XCTAssertEqual(ExcerptFormat.copyrightLine(.publicDomain, region: .us), "Public domain in the US")
        XCTAssertEqual(ExcerptFormat.copyrightLine(.protected, region: .eu), "Protected in the EU")
        XCTAssertEqual(ExcerptFormat.copyrightLine(.publicDomain, region: .ca), "Public domain in Canada")
    }

    func testDisplayDate() {
        XCTAssertFalse(ExcerptFormat.displayDate("2026-10-10").isEmpty)
        XCTAssertNotEqual(ExcerptFormat.displayDate("2026-10-10"), "2026-10-10")
        XCTAssertEqual(ExcerptFormat.displayDate("not a date"), "not a date")
    }

    func testVariantLine() {
        let variant = LocationVariant(location: ExcerptLocation(text: "II: mm. 1-10"), orchestra: "Dallas Symphony Orchestra",
                                      year: 2025, position: .section, source: "https://example.org/list.pdf", asOf: "2026-10-10")
        XCTAssertEqual(ExcerptFormat.variantLine(variant), "Dallas Symphony Orchestra 2025: II: mm. 1-10")
        let bare = LocationVariant(location: ExcerptLocation(text: "mm. 5-9"), source: "https://example.org", asOf: "2026-10-10")
        XCTAssertEqual(ExcerptFormat.variantLine(bare), "mm. 5-9")
    }

    func testRateLabel() {
        XCTAssertEqual(ExcerptFormat.rateLabel(0.5), "0.5×")
        XCTAssertEqual(ExcerptFormat.rateLabel(1), "1×")
        XCTAssertEqual(ExcerptFormat.rateLabel(1.25), "1.25×")
    }

    // MARK: Links

    func testOpenInYouTubeURL() {
        XCTAssertEqual(ExcerptLinks.openInYouTubeURL(videoId: "abc", startSeconds: 82)?.absoluteString,
                       "https://www.youtube.com/watch?v=abc&t=82s")
        XCTAssertEqual(ExcerptLinks.openInYouTubeURL(videoId: "abc", startSeconds: nil)?.absoluteString,
                       "https://www.youtube.com/watch?v=abc")
    }

    func testSearchURLs() throws {
        let excerpt = makeExcerpt(id: "x", composer: "Ludwig van Beethoven", work: "Symphony No. 5 in C minor")
        let youtube = try XCTUnwrap(ExcerptLinks.youtubeSearchURL(for: excerpt))
        XCTAssertEqual(youtube.host, "www.youtube.com")
        XCTAssertEqual(youtube.path, "/results")
        XCTAssertTrue(youtube.absoluteString.contains("search_query="))
        XCTAssertTrue(youtube.absoluteString.contains("Beethoven"))

        let appleMusic = try XCTUnwrap(ExcerptLinks.appleMusicSearchURL(for: excerpt))
        XCTAssertEqual(appleMusic.host, "music.apple.com")
        XCTAssertTrue(appleMusic.absoluteString.contains("term="))

        let imslp = try XCTUnwrap(ExcerptLinks.imslpURL(for: excerpt))
        XCTAssertEqual(imslp.host, "imslp.org")
        XCTAssertTrue(imslp.absoluteString.contains("Special:Search"))

        var withPage = excerpt
        withPage.workIds = WorkIds(imslpPage: "Symphony_No.5,_Op.67_(Beethoven,_Ludwig_van)")
        let page = try XCTUnwrap(ExcerptLinks.imslpURL(for: withPage))
        XCTAssertFalse(page.absoluteString.contains("Special:Search"))
        XCTAssertEqual(page.host, "imslp.org")
    }

    // MARK: Feedback address

    func testFeedbackHiddenUntilConfigured() {
        XCTAssertFalse(FeedbackConfig.isConfigured())
        XCTAssertFalse(FeedbackConfig.isConfigured("someone@test.example.com"))
        XCTAssertTrue(FeedbackConfig.isConfigured("team@auditioner.app"))
        XCTAssertNil(FeedbackConfig.reportURL(excerptId: "e", section: "history", origin: .ai))
        let url = FeedbackConfig.reportURL(excerptId: "cello-x", section: "history", origin: .ai, address: "team@auditioner.app")
        XCTAssertEqual(url?.scheme, "mailto")
        XCTAssertTrue(url?.absoluteString.hasPrefix("mailto:team@auditioner.app?") ?? false)
        XCTAssertTrue(url?.absoluteString.contains("subject=") ?? false)
    }

    // MARK: Browser filtering and grouping

    func testPositionFilter() {
        let principalOnly = makeExcerpt(id: "a", composer: "A B", work: "W", positions: [.principal])
        let anyPosition = makeExcerpt(id: "b", composer: "A B", work: "W", positions: [.any])
        let section = makeExcerpt(id: "c", composer: "A B", work: "W", positions: [.section, .principal])
        let pool = [principalOnly, anyPosition, section]

        let forSection = ExcerptBrowserLogic.filter(pool, position: .position(.section), tier: .all).map { $0.id }
        XCTAssertEqual(forSection, ["b", "c"])
        let all = ExcerptBrowserLogic.filter(pool, position: .all, tier: .all).map { $0.id }
        XCTAssertEqual(all, ["a", "b", "c"])
        let anyChoice = ExcerptBrowserLogic.filter(pool, position: .position(.any), tier: .all).map { $0.id }
        XCTAssertEqual(anyChoice, ["a", "b", "c"])
    }

    func testTierFilterCountsOnlyVerifiedTiers() {
        let unverifiedCore = makeExcerpt(id: "u", composer: "A B", work: "W", tier: .core, tierStatus: .unverified)
        let verifiedCore = makeExcerpt(id: "v", composer: "A B", work: "W", tier: .core, tierStatus: .verified)
        let none = makeExcerpt(id: "n", composer: "A B", work: "W")
        let pool = [unverifiedCore, verifiedCore, none]
        XCTAssertEqual(ExcerptBrowserLogic.filter(pool, position: .all, tier: .tier(.core)).map { $0.id }, ["v"])
        XCTAssertEqual(ExcerptBrowserLogic.filter(pool, position: .all, tier: .all).count, 3)
    }

    func testGroupingBySurname() {
        let strauss = makeExcerpt(id: "s", composer: "Richard Strauss", work: "Don Juan")
        let beethoven5 = makeExcerpt(id: "b5", composer: "Ludwig van Beethoven", work: "Symphony No. 5", movement: 2)
        let beethoven5a = makeExcerpt(id: "b5a", composer: "Ludwig van Beethoven", work: "Symphony No. 5", movement: 3)
        let bartok = makeExcerpt(id: "bk", composer: "Béla Bartók", work: "Concerto for Orchestra")
        let sections = ExcerptBrowserLogic.group([strauss, beethoven5a, bartok, beethoven5])
        XCTAssertEqual(sections.map { $0.title }, ["Bartók", "Beethoven", "Strauss"])
        XCTAssertEqual(sections[1].excerpts.map { $0.id }, ["b5", "b5a"])
    }

    func testOrderedInstruments() {
        let ordered = ExcerptBrowserLogic.orderedInstruments(withContent: [.horn, .cello])
        XCTAssertEqual(ordered.first, [.cello, .horn])
        XCTAssertFalse(ordered.more.contains(.cello))
        XCTAssertEqual(ordered.first.count + ordered.more.count, Instrument.allCases.count)
        XCTAssertFalse(ExcerptBrowserLogic.filterablePositions.contains(.any))
    }

    // MARK: Marks store

    func testMarkStoreUpdatesExistingMark() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TimestampMark.self, configurations: configuration)
        let context = ModelContext(container)

        try TimestampMarkStore.save(excerptId: "e1", recordingId: "r1", youtubeId: "v", start: 10, end: nil, in: context)
        try TimestampMarkStore.save(excerptId: "e1", recordingId: "r1", youtubeId: "v", start: 10, end: 20, in: context)

        let all = try context.fetch(FetchDescriptor<TimestampMark>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.startSeconds, 10)
        XCTAssertEqual(all.first?.endSeconds, 20)
        XCTAssertNotNil(TimestampMarkStore.existing(excerptId: "e1", recordingId: "r1", in: context))
        XCTAssertNil(TimestampMarkStore.existing(excerptId: "e1", recordingId: "other", in: context))
    }

    func testRecordingMarksLoopRange() {
        let excerpt = makeExcerpt(id: "e", composer: "A B", work: "W")
        let recording = Recording(id: "r", kind: .solo, provider: .youtube, title: "T", youtubeId: "abc")
        let marks = RecordingMarks(excerpt: excerpt, recording: recording)
        XCTAssertNil(marks.loopRange)
        XCTAssertEqual(marks.youtubeId, "abc")
    }
}
