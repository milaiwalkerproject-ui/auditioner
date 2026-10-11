import XCTest
import SwiftData
@testable import Auditioner

/// Pure logic behind the Auditions tab and "My upcoming audition". Fixtures are synthetic: made-up
/// composers, works and list lines — never a real orchestra's list.
final class AuditionsTests: XCTestCase {

    // MARK: Fixtures

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// Builds an excerpt the way the app does (JSON), so the test doesn't depend on the memberwise init.
    private func makeExcerpt(id: String,
                             composer: String,
                             work: String,
                             title: String = "Opening",
                             catalogueNumber: String? = nil,
                             movementNumber: Int? = nil,
                             movementTitle: String? = nil,
                             difficulty: Int? = nil,
                             difficultyApproved: Bool = true,
                             instrument: String = "cello") throws -> Excerpt {
        var fields: [String] = [
            "\"id\": \"\(id)\"",
            "\"instrument\": \"\(instrument)\"",
            "\"positions\": [\"section\"]",
            "\"composer\": \"\(composer)\"",
            "\"work\": \"\(work)\"",
            "\"title\": \"\(title)\"",
            "\"location\": {\"status\": \"unverified\"}",
            "\"sources\": []",
            "\"listingStatus\": \"published\"",
        ]
        if let catalogueNumber {
            fields.append("\"catalogueNumber\": \"\(catalogueNumber)\"")
        }
        if movementNumber != nil || movementTitle != nil {
            var movement: [String] = []
            if let movementNumber { movement.append("\"number\": \(movementNumber)") }
            if let movementTitle { movement.append("\"title\": \"\(movementTitle)\"") }
            fields.append("\"movement\": {" + movement.joined(separator: ", ") + "}")
        }
        if let difficulty {
            let status: String = difficultyApproved ? "approved" : "draft"
            fields.append("\"difficulty\": {\"value\": \(difficulty), \"origin\": \"curated\", \"reviewStatus\": \"\(status)\"}")
        }
        let json = "{" + fields.joined(separator: ", ") + "}"
        return try JSONDecoder().decode(Excerpt.self, from: Data(json.utf8))
    }

    /// A small made-up catalogue.
    private func makePool() throws -> [Excerpt] {
        [
            try makeExcerpt(id: "cello-quill-symphony-2-mvt2", composer: "Ada Quill", work: "Symphony No. 2 in D major",
                            catalogueNumber: "Op. 11", movementNumber: 2, movementTitle: "Adagio", difficulty: 3),
            try makeExcerpt(id: "cello-quill-symphony-3-mvt3", composer: "Ada Quill", work: "Symphony No. 3 in F major",
                            catalogueNumber: "Op. 12", movementNumber: 3, movementTitle: "Poco allegretto", difficulty: 4),
            try makeExcerpt(id: "cello-reine-symphony-2-mvt2", composer: "Tomas Reine", work: "Symphony No. 2 in C minor",
                            title: "Opening and variations", catalogueNumber: "Op. 40", movementNumber: 2, movementTitle: "Andante"),
            try makeExcerpt(id: "cello-reine-symphony-2-mvt3", composer: "Tomas Reine", work: "Symphony No. 2 in C minor",
                            title: "Scherzo and trio", catalogueNumber: "Op. 40", movementNumber: 3, movementTitle: "Scherzo"),
            try makeExcerpt(id: "cello-holt-ein-lied-opening", composer: "Mira Holt", work: "Ein Lied", catalogueNumber: "Op. 7", difficulty: 5),
        ]
    }

    private func makeVacancy(id: String = "vac-1",
                             deadline: String? = "2026-11-03",
                             auditionDates: [String] = ["2026-11-20", "2026-11-21"],
                             completeness: String = "full",
                             items: [FeedVacancyItem]? = nil) -> FeedVacancy {
        FeedVacancy(id: id,
                    orchestra: "Example Philharmonic",
                    orchestraId: "example-philharmonic",
                    region: "europe-other",
                    position: "Section cello",
                    instrument: "cello",
                    applicationDeadline: deadline,
                    auditionDates: auditionDates,
                    listCompleteness: completeness,
                    sourceURL: "https://example.org/auditions/cello.pdf",
                    lastCheckedAt: "2026-10-10",
                    items: items ?? [
                        FeedVacancyItem(rawText: "Quill: Symphony No. 2, mvt. II", category: "excerpt", round: "Preliminary", excerptId: "cello-quill-symphony-2-mvt2"),
                        FeedVacancyItem(rawText: "A concerto movement of your choice", category: "solo", round: "", excerptId: nil),
                        FeedVacancyItem(rawText: "   ", category: "excerpt", round: "", excerptId: nil),
                        FeedVacancyItem(rawText: "Holt: Ein Lied", category: "excerpt", round: "Final", excerptId: "  "),
                    ])
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Audition.self, AuditionItem.self, configurations: configuration)
    }

    // MARK: - Countdown

    func testCountdownDaysAndPhrases() {
        let now = day(2026, 10, 11, hour: 23, minute: 30)
        XCTAssertEqual(AuditionCountdown.days(from: now, to: day(2026, 10, 23, hour: 1), calendar: calendar), 12)
        XCTAssertEqual(AuditionCountdown.phrase(to: day(2026, 10, 23), now: now, calendar: calendar), "in 12 days")
        XCTAssertEqual(AuditionCountdown.phrase(to: day(2026, 10, 12, hour: 0, minute: 5), now: now, calendar: calendar), "tomorrow")
        XCTAssertEqual(AuditionCountdown.phrase(to: day(2026, 10, 11, hour: 8), now: now, calendar: calendar), "today")
        XCTAssertEqual(AuditionCountdown.phrase(to: day(2026, 10, 10), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(AuditionCountdown.phrase(to: day(2026, 10, 1), now: now, calendar: calendar), "10 days ago")
        XCTAssertEqual(AuditionCountdown.capitalized("in 12 days"), "In 12 days")
        XCTAssertTrue(AuditionCountdown.isPast(days: -1))
        XCTAssertFalse(AuditionCountdown.isPast(days: 0))
    }

    func testCountdownAcrossDaylightSavingChange() {
        // Berlin leaves summer time on 25 Oct 2026; whole days are still whole days.
        let now = day(2026, 10, 24)
        XCTAssertEqual(AuditionCountdown.days(from: now, to: day(2026, 10, 26), calendar: calendar), 2)
    }

    // MARK: - Readiness

    func testReadinessShareAndLabel() {
        XCTAssertEqual(AuditionReadiness.share([]), 0)
        XCTAssertEqual(AuditionReadiness.share([nil, 1, 3]), 0)
        XCTAssertEqual(AuditionReadiness.share([4, 5, 2, nil]), 0.5)
        XCTAssertEqual(AuditionReadiness.share([5, 5]), 1)
        XCTAssertEqual(AuditionReadiness.readyCount([4, 3, 5, nil]), 2)
        XCTAssertEqual(AuditionReadiness.label([4, 3, 5, nil]), "2 of 4 ready")
        XCTAssertEqual(AuditionReadiness.label([]), "No items yet")
        XCTAssertEqual(AuditionReadiness.clamp(9), 5)
        XCTAssertEqual(AuditionReadiness.clamp(0), 1)
        XCTAssertNil(AuditionReadiness.clamp(nil))
        XCTAssertFalse(AuditionReadiness.isReady(3))
        XCTAssertTrue(AuditionReadiness.isReady(4))
    }

    // MARK: - Rounds and categories

    func testRoundsCanonicalRankAndNames() {
        XCTAssertEqual(AuditionRounds.canonical("preliminary round"), "Preliminary")
        XCTAssertEqual(AuditionRounds.canonical("Prelims"), "Preliminary")
        XCTAssertEqual(AuditionRounds.canonical("Semi final"), "Semi-final")
        XCTAssertEqual(AuditionRounds.canonical("semifinals"), "Semi-final")
        XCTAssertEqual(AuditionRounds.canonical("FINAL"), "Final")
        XCTAssertEqual(AuditionRounds.canonical("Round 2"), "Semi-final")
        XCTAssertEqual(AuditionRounds.canonical("All rounds"), "")
        XCTAssertEqual(AuditionRounds.canonical("  "), "")
        XCTAssertEqual(AuditionRounds.canonical("Super-final"), "Super-final")

        XCTAssertEqual(AuditionRounds.rank(""), 0)
        XCTAssertEqual(AuditionRounds.rank("Preliminary"), 1)
        XCTAssertEqual(AuditionRounds.rank("Semi-final"), 2)
        XCTAssertEqual(AuditionRounds.rank("Final"), 3)
        XCTAssertEqual(AuditionRounds.rank("Super-final"), 4)
        XCTAssertEqual(AuditionRounds.displayName(""), "All rounds")
        XCTAssertEqual(AuditionRounds.displayName("Preliminary"), "Preliminary round")
    }

    func testCategoriesMapUnknownToOther() {
        XCTAssertEqual(AuditionItemCategory(raw: "sight_reading"), .sightReading)
        XCTAssertEqual(AuditionItemCategory(raw: "nonsense"), .other)
        XCTAssertFalse(AuditionItemCategory.sightReading.isPractisable)
        XCTAssertTrue(AuditionItemCategory.solo.isPractisable)
        XCTAssertLessThan(AuditionItemCategory.solo.rank, AuditionItemCategory.excerpt.rank)
    }

    // MARK: - Grouping

    private struct Line: Equatable {
        var text: String
        var round: String
        var category: String
        var order: Int
    }

    func testGroupingByRoundThenCategoryKeepsItemOrder() {
        let lines: [Line] = [
            Line(text: "final excerpt", round: "Final", category: "excerpt", order: 5),
            Line(text: "prelim excerpt B", round: "preliminary round", category: "excerpt", order: 3),
            Line(text: "solo", round: "", category: "solo", order: 4),
            Line(text: "prelim excerpt A", round: "Preliminary", category: "excerpt", order: 1),
            Line(text: "prelim solo", round: "Preliminary", category: "solo", order: 2),
            Line(text: "reading", round: "", category: "sight_reading", order: 0),
        ]
        let groups = AuditionItemGrouping.groups(lines, round: { $0.round }, category: { $0.category }, order: { $0.order })
        XCTAssertEqual(groups.map { $0.id }, ["|solo", "|sight_reading", "Preliminary|solo", "Preliminary|excerpt", "Final|excerpt"])
        XCTAssertEqual(groups[3].items.map { $0.text }, ["prelim excerpt A", "prelim excerpt B"])
        XCTAssertTrue(AuditionItemGrouping.showsRounds(groups))
        XCTAssertEqual(groups[3].title(showRound: true), "Preliminary round · Orchestral excerpts")
        XCTAssertEqual(groups[3].title(showRound: false), "Orchestral excerpts")

        let single = AuditionItemGrouping.groups([lines[0]], round: { $0.round }, category: { $0.category }, order: { $0.order })
        XCTAssertFalse(AuditionItemGrouping.showsRounds(single))
    }

    // MARK: - Practice plan

    func testPracticePlanOrdering() {
        let a = PracticePlanCandidate(id: UUID(), readiness: 2, roundRank: 1, difficulty: 3, order: 0)
        let b = PracticePlanCandidate(id: UUID(), readiness: nil, roundRank: 3, difficulty: 2, order: 1)   // not rated → first
        let c = PracticePlanCandidate(id: UUID(), readiness: 2, roundRank: 1, difficulty: 5, order: 2)     // harder than a
        let d = PracticePlanCandidate(id: UUID(), readiness: 2, roundRank: 0, difficulty: nil, order: 3)   // earlier round than a/c
        let e = PracticePlanCandidate(id: UUID(), readiness: 5, roundRank: 0, difficulty: 5, order: 4)     // ready → last
        let reading = PracticePlanCandidate(id: UUID(), readiness: nil, roundRank: 0, difficulty: nil, order: 5, isPractisable: false)
        let ordered = AuditionPracticePlan.ordered([a, b, c, d, e, reading])
        XCTAssertEqual(ordered.map { $0.id }, [b.id, d.id, c.id, a.id, e.id])
        XCTAssertEqual(AuditionPracticePlan.practiseNext([a, b, c, d, e, reading]).map { $0.id }, [b.id, d.id, c.id])
        XCTAssertEqual(AuditionPracticePlan.practiseNext([a], limit: 0), [])
    }

    func testApprovedDifficultyOnly() throws {
        let approved = try makeExcerpt(id: "x-1", composer: "Ada Quill", work: "Ein Lied", difficulty: 4)
        let draft = try makeExcerpt(id: "x-2", composer: "Ada Quill", work: "Ein Lied", difficulty: 4, difficultyApproved: false)
        let none = try makeExcerpt(id: "x-3", composer: "Ada Quill", work: "Ein Lied")
        XCTAssertEqual(AuditionPracticePlan.approvedDifficulty(approved), 4)
        XCTAssertNil(AuditionPracticePlan.approvedDifficulty(draft))
        XCTAssertNil(AuditionPracticePlan.approvedDifficulty(none))
        XCTAssertNil(AuditionPracticePlan.approvedDifficulty(nil))
    }

    // MARK: - Dates

    func testParseDayAcceptsISODaysOnly() {
        XCTAssertEqual(AuditionDates.parseDay("2026-11-03", calendar: calendar), day(2026, 11, 3))
        XCTAssertEqual(AuditionDates.parseDay(" 2026-11-03T00:00:00Z ", calendar: calendar), day(2026, 11, 3))
        XCTAssertNil(AuditionDates.parseDay("2026-02-31", calendar: calendar))
        XCTAssertNil(AuditionDates.parseDay("3 November 2026", calendar: calendar))
        XCTAssertNil(AuditionDates.parseDay("", calendar: calendar))
        XCTAssertNil(AuditionDates.parseDay(nil, calendar: calendar))
        XCTAssertEqual(AuditionDates.dayString(day(2026, 11, 3), calendar: calendar), "2026-11-03")
        XCTAssertEqual(AuditionDates.earliestDay(["2026-11-21", "not a date", "2026-11-20"], calendar: calendar), day(2026, 11, 20))
        XCTAssertNil(AuditionDates.earliestDay(["tba"], calendar: calendar))
        XCTAssertEqual(AuditionDates.noon(of: day(2026, 11, 3, hour: 22), calendar: calendar), day(2026, 11, 3))
    }

    func testSortDatePrefersAuditionDayThenDeadline() {
        let deadline = day(2026, 11, 3)
        let audition = day(2026, 11, 20)
        XCTAssertEqual(AuditionOrdering.sortDate(auditionDate: audition, deadline: deadline), audition)
        XCTAssertEqual(AuditionOrdering.sortDate(auditionDate: nil, deadline: deadline), deadline)
        XCTAssertEqual(AuditionOrdering.sortDate(auditionDate: nil, deadline: nil), Date.distantFuture)
    }

    // MARK: - Completeness

    func testCompletenessBadges() {
        XCTAssertEqual(ListCompleteness(raw: "full").badgeText, "Full list")
        XCTAssertEqual(ListCompleteness(raw: "partial_public").badgeText, "Partial list — more sent to invited candidates")
        XCTAssertEqual(ListCompleteness(raw: "works_only").badgeText, "Works only")
        XCTAssertEqual(ListCompleteness(raw: "revealed_on_invitation").badgeText, "List sent with invitation")
        XCTAssertNil(ListCompleteness(raw: "unknown").badgeText)
        XCTAssertNil(ListCompleteness(raw: "something else").badgeText)
        XCTAssertEqual(ListCompleteness(raw: "something else"), .unknown)
        XCTAssertNotNil(ListCompleteness.worksOnly.note)
        XCTAssertNil(ListCompleteness.unknown.note)
    }

    // MARK: - Open auditions feed

    func testOpenAuditionsFilterAndOrder() {
        let today = day(2026, 10, 11)
        let soon = makeVacancy(id: "soon", deadline: "2026-10-20")
        let later = makeVacancy(id: "later", deadline: "2026-12-01")
        let noDeadline = makeVacancy(id: "none", deadline: nil)
        let closed = makeVacancy(id: "closed", deadline: "2026-10-10")
        let todayDeadline = makeVacancy(id: "today", deadline: "2026-10-11")
        let sorted = OpenAuditionsLogic.openSorted([later, noDeadline, closed, soon, todayDeadline], today: today, calendar: calendar)
        XCTAssertEqual(sorted.map { $0.id }, ["today", "soon", "later", "none"])
        XCTAssertTrue(OpenAuditionsLogic.isOpen(noDeadline, today: today, calendar: calendar))
        XCTAssertFalse(OpenAuditionsLogic.isOpen(closed, today: today, calendar: calendar))
    }

    func testFeedRegionFollowsTheAllRegionsSwitch() {
        // PLAN F5: "All regions" sends no region, so the server answers with every region.
        XCTAssertEqual(OpenAuditionsLogic.feedRegion(allRegions: false, region: "uk"), "uk")
        XCTAssertEqual(OpenAuditionsLogic.feedRegion(allRegions: false, region: " europe-other "), "europe-other")
        XCTAssertNil(OpenAuditionsLogic.feedRegion(allRegions: true, region: "uk"))
        XCTAssertNil(OpenAuditionsLogic.feedRegion(allRegions: false, region: "   "), "a blank region means every region")
        XCTAssertEqual(OpenAuditionsLogic.scopeTitle(allRegions: false, regionName: "North America"), "Your region (North America)")
        XCTAssertEqual(OpenAuditionsLogic.scopeTitle(allRegions: true, regionName: "North America"), "All regions")
        XCTAssertEqual(OpenAuditionsLogic.allRegionsKey, "auditions.feedAllRegions")
    }

    @MainActor
    func testAllRegionsChoiceIsRemembered() {
        let suiteName: String = "AuditionsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("no defaults suite") }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(OpenAuditionsLogic.showsAllRegions(defaults), "the player's region until they choose otherwise")
        let model = OpenAuditionsFeedModel(defaults: defaults)
        XCTAssertFalse(model.allRegions)
        model.setAllRegions(true)
        XCTAssertTrue(model.allRegions)
        XCTAssertTrue(OpenAuditionsLogic.showsAllRegions(defaults))
        XCTAssertTrue(OpenAuditionsFeedModel(defaults: defaults).allRegions, "a new model starts from the remembered choice")
        model.setAllRegions(false)
        XCTAssertFalse(OpenAuditionsLogic.showsAllRegions(defaults))
    }

    func testFeedSourceLineAndInstrument() {
        XCTAssertEqual(OpenAuditionsLogic.sourceLine(orchestra: "Example Philharmonic", lastCheckedAt: nil),
                       "From Example Philharmonic's website")
        XCTAssertTrue(OpenAuditionsLogic.sourceLine(orchestra: "Example Philharmonic", lastCheckedAt: "2026-10-10")
            .hasPrefix("From Example Philharmonic's website, checked "))
        XCTAssertEqual(OpenAuditionsLogic.instrument(for: makeVacancy(), fallback: .horn), .cello)
        var odd = makeVacancy()
        odd.instrument = "theremin"
        XCTAssertEqual(OpenAuditionsLogic.instrument(for: odd, fallback: .horn), .horn)
        XCTAssertNil(OpenAuditionsLogic.auditionDatesLine([], calendar: calendar))
        XCTAssertTrue(OpenAuditionsLogic.auditionDatesLine(["2026-11-20"], calendar: calendar)!.hasPrefix("Audition "))
        XCTAssertTrue(OpenAuditionsLogic.auditionDatesLine(["2026-11-20", "tba"], calendar: calendar)!.hasSuffix(", tba"))
    }

    // MARK: - Reminders

    func testReminderScheduleDatesIdentifiersAndSkippingThePast() {
        let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!
        let now = day(2026, 10, 11, hour: 10)
        let deadline = day(2026, 10, 15)      // 7 days before = 8 Oct (past) → only the 1-day reminder
        let auditionDate = day(2026, 11, 20)  // both reminders
        let reminders = AuditionReminderSchedule.reminders(auditionId: id, orchestra: "Example Philharmonic", position: "Section cello",
                                                           deadline: deadline, auditionDate: auditionDate, now: now, calendar: calendar)
        XCTAssertEqual(reminders.map { $0.identifier }, [
            "audition-0a1b2c3d-0000-4000-8000-000000000001-deadline-1",
            "audition-0a1b2c3d-0000-4000-8000-000000000001-audition-7",
            "audition-0a1b2c3d-0000-4000-8000-000000000001-audition-1",
        ])
        XCTAssertEqual(reminders[0].fireDate, day(2026, 10, 14, hour: 9))
        XCTAssertEqual(reminders[1].fireDate, day(2026, 11, 13, hour: 9))
        XCTAssertEqual(reminders[2].fireDate, day(2026, 11, 19, hour: 9))
        XCTAssertEqual(reminders[0].title, "Application deadline tomorrow")
        XCTAssertEqual(reminders[1].title, "Audition in 7 days")
        XCTAssertTrue(reminders[1].body.hasPrefix("Example Philharmonic (Section cello): audition on "))

        XCTAssertEqual(AuditionReminderSchedule.identifiers(auditionId: id).count, 4)
        XCTAssertTrue(AuditionReminderSchedule.identifiers(auditionId: id).contains("audition-0a1b2c3d-0000-4000-8000-000000000001-deadline-7"))

        let none = AuditionReminderSchedule.reminders(auditionId: id, orchestra: "X", position: "", deadline: nil, auditionDate: nil, now: now, calendar: calendar)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(AuditionReminderSchedule.summary(none, calendar: calendar).contains("nothing to remind"))
        XCTAssertTrue(AuditionReminderSchedule.summary(reminders, calendar: calendar).hasPrefix("Reminders at 9:00 on "))

        // A reminder exactly at "now" is not planned; one minute later is.
        let edge = AuditionReminderSchedule.reminders(auditionId: id, orchestra: "X", position: "", deadline: day(2026, 10, 12), auditionDate: nil,
                                                      now: day(2026, 10, 11, hour: 9), calendar: calendar)
        XCTAssertTrue(edge.isEmpty)
        let justBefore = AuditionReminderSchedule.reminders(auditionId: id, orchestra: "X", position: "", deadline: day(2026, 10, 12), auditionDate: nil,
                                                            now: day(2026, 10, 11, hour: 8, minute: 59), calendar: calendar)
        XCTAssertEqual(justBefore.count, 1)
    }

    // MARK: - Reordering and tempo

    func testReorderedOrdersKeepTheSectionsSlots() {
        XCTAssertEqual(AuditionBuilder.reorderedOrders([2, 5, 7], from: IndexSet(integer: 0), to: 3), [7, 2, 5])
        XCTAssertEqual(AuditionBuilder.reorderedOrders([2, 5, 7], from: IndexSet(integer: 2), to: 0), [5, 7, 2])
        XCTAssertEqual(AuditionBuilder.reorderedOrders([0, 1], from: IndexSet(integer: 0), to: 1), [0, 1])
        // Same semantics as a SwiftUI list's move: picked rows go in front of the row that sat at `to` before the move.
        XCTAssertEqual(AuditionBuilder.moved(["a", "b", "c", "d"], from: IndexSet([0, 2]), to: 4), ["b", "d", "a", "c"])
        XCTAssertEqual(AuditionBuilder.moved(["a", "b", "c"], from: IndexSet(integer: 2), to: 0), ["c", "a", "b"])
        XCTAssertEqual(AuditionBuilder.moved(["a", "b", "c"], from: IndexSet(integer: 1), to: 1), ["a", "b", "c"], "moving a row onto its own slot changes nothing")
        XCTAssertEqual(AuditionBuilder.moved(["a", "b", "c"], from: IndexSet(integer: 9), to: 0), ["a", "b", "c"], "offsets outside the list are ignored")
        XCTAssertEqual(AuditionBuilder.nextOrder(existingOrders: []), 0)
        XCTAssertEqual(AuditionBuilder.nextOrder(existingOrders: [3, 9, 4]), 10)
    }

    func testTempoParsing() {
        XCTAssertEqual(AuditionTempo.parse("96"), 96)
        XCTAssertEqual(AuditionTempo.parse(" 88,5 "), 88.5)
        XCTAssertEqual(AuditionTempo.parse("5"), 20)
        XCTAssertEqual(AuditionTempo.parse("9999"), 400)
        XCTAssertNil(AuditionTempo.parse(""))
        XCTAssertNil(AuditionTempo.parse("fast"))
        XCTAssertNil(AuditionTempo.parse("-10"))
        XCTAssertEqual(AuditionTempo.text(96), "96")
        XCTAssertEqual(AuditionTempo.text(nil), "")
        XCTAssertNil(AuditionTempo.summary(target: nil, achieved: nil))
        XCTAssertEqual(AuditionTempo.summary(target: 96, achieved: 72), "At 72, aiming for 96")
        XCTAssertEqual(AuditionTempo.summary(target: 96, achieved: nil), "Aiming for 96")
    }

    func testFormKeepsOnlyWebLinks() {
        XCTAssertEqual(AuditionFormLogic.cleanedSourceURL(" https://example.org/list.pdf "), "https://example.org/list.pdf")
        XCTAssertNil(AuditionFormLogic.cleanedSourceURL("mailto:someone@example.org"))
        XCTAssertNil(AuditionFormLogic.cleanedSourceURL("not a link"))
        XCTAssertNil(AuditionFormLogic.cleanedSourceURL(""))
    }

    // MARK: - List parser

    func testParserHeadingsNumberingAndCategories() {
        let lines: [String] = [
            "Audition repertoire",
            "Page 1 of 2",
            "Preliminary round:",
            "1. Quill: Symphony No. 2, mvt. II, mm. 1–15",
            "2) Quill – Symphony No. 3, mvt. III",
            "Solo:",
            "A concerto movement of your choice",
            "SEMI-FINAL",
            "• Reine Sym. 2/II",
            "Final",
            "Holt: Ein Lied",
            "Sight-reading may be requested.",
            "",
        ]
        let items = AuditionListParser.parse(lines: lines)
        XCTAssertEqual(items.count, 6)

        XCTAssertEqual(items[0].rawText, "Quill: Symphony No. 2, mvt. II, mm. 1–15")
        XCTAssertEqual(items[0].round, "Preliminary")
        XCTAssertEqual(items[0].category, "excerpt")
        XCTAssertEqual(items[0].composer, "Quill")
        XCTAssertEqual(items[0].work, "Symphony No. 2, mvt. II, mm. 1–15")
        XCTAssertEqual(items[0].movementNumber, 2)
        XCTAssertEqual(items[0].bars, BarRange(start: 1, end: 15))

        XCTAssertEqual(items[1].rawText, "Quill – Symphony No. 3, mvt. III")
        XCTAssertEqual(items[1].composer, "Quill")
        XCTAssertEqual(items[1].movementNumber, 3)
        XCTAssertNil(items[1].bars)

        XCTAssertEqual(items[2].rawText, "A concerto movement of your choice")
        XCTAssertEqual(items[2].round, "Preliminary")
        XCTAssertEqual(items[2].category, "solo")

        XCTAssertEqual(items[3].rawText, "Reine Sym. 2/II")
        XCTAssertEqual(items[3].round, "Semi-final")
        XCTAssertEqual(items[3].category, "excerpt", "a round heading resets the category")
        XCTAssertEqual(items[3].composer, "Reine")
        XCTAssertEqual(items[3].work, "Sym. 2/II")
        XCTAssertEqual(items[3].movementNumber, 2)

        XCTAssertEqual(items[4].rawText, "Holt: Ein Lied")
        XCTAssertEqual(items[4].round, "Final")
        XCTAssertEqual(items[4].composer, "Holt")
        XCTAssertEqual(items[4].work, "Ein Lied")
        XCTAssertNil(items[4].movementNumber)

        XCTAssertEqual(items[5].category, "sight_reading")
        XCTAssertEqual(items[5].round, "Final")
    }

    func testParserJoinsContinuationLines() {
        let items = AuditionListParser.parse(text: """
        Quill: Symphony No. 2
        mvt. II, mm. 12–40
        Reine: Symphony No. 2
        (beginning to bar 24)
        Holt: Ein Lied
        """)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].rawText, "Quill: Symphony No. 2 mvt. II, mm. 12–40")
        XCTAssertEqual(items[0].movementNumber, 2)
        XCTAssertEqual(items[0].bars, BarRange(start: 12, end: 40))
        XCTAssertEqual(items[1].rawText, "Reine: Symphony No. 2 (beginning to bar 24)")
        XCTAssertEqual(items[1].bars, BarRange(start: 1, end: 24))
        XCTAssertEqual(items[2].rawText, "Holt: Ein Lied")
    }

    func testParserComposerWorkForms() {
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill: Symphony No. 2").composer, "Quill")
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill – Symphony No. 2").work, "Symphony No. 2")
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill - Symphony No. 2").composer, "Quill")
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill, Symphony No. 2").composer, "Quill")
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill Sym. 5/II").composer, "Quill")
        XCTAssertEqual(AuditionListParser.splitComposerWork("A. Quill Symphony No. 2").composer, "A. Quill")
        XCTAssertEqual(AuditionListParser.splitComposerWork("A. Quill Symphony No. 2").work, "Symphony No. 2")
        XCTAssertEqual(AuditionListParser.splitComposerWork("Quill, A.: Symphony No. 2").composer, "Quill, A.")
        XCTAssertNil(AuditionListParser.splitComposerWork("Symphony No. 2, mvt. II").composer)
        XCTAssertNil(AuditionListParser.splitComposerWork("Ein Lied").composer)
        XCTAssertNil(AuditionListParser.splitComposerWork("").composer)
    }

    func testParserMovementAndBars() {
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Symphony No. 2, mvt. II"), 2)
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Symphony No. 2, Mvt 4"), 4)
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Symphony No. 2, 3rd movement"), 3)
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Sym. 5/IV"), 4)
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Symphony No. 2, II, mm. 1–20"), 2)
        XCTAssertEqual(AuditionListParser.movementNumber(in: "Sinfonie Nr. 2, 2. Satz"), 2)
        XCTAssertNil(AuditionListParser.movementNumber(in: "Symphony in C"))
        XCTAssertNil(AuditionListParser.movementNumber(in: "Ein Lied"))
        XCTAssertEqual(AuditionListParser.romanValue("iv"), 4)
        XCTAssertEqual(AuditionListParser.romanValue("IX"), 9)
        XCTAssertNil(AuditionListParser.romanValue("abc"))

        XCTAssertEqual(AuditionListParser.barRange(in: "mm. 12–40"), BarRange(start: 12, end: 40))
        XCTAssertEqual(AuditionListParser.barRange(in: "bars 12 to 40"), BarRange(start: 12, end: 40))
        XCTAssertEqual(AuditionListParser.barRange(in: "from m. 12 to m. 40"), BarRange(start: 12, end: 40))
        XCTAssertEqual(AuditionListParser.barRange(in: "measures 5-20"), BarRange(start: 5, end: 20))
        XCTAssertEqual(AuditionListParser.barRange(in: "beginning to bar 40"), BarRange(start: 1, end: 40))
        XCTAssertEqual(AuditionListParser.barRange(in: "from bar 12"), BarRange(start: 12, end: nil))
        XCTAssertNil(AuditionListParser.barRange(in: "Op. 10 No. 12"))
        XCTAssertNil(AuditionListParser.barRange(in: "1812 Overture"))
    }

    func testParserHelpers() {
        XCTAssertEqual(AuditionListParser.roundHeading("Preliminary Round Repertoire"), "Preliminary")
        XCTAssertEqual(AuditionListParser.roundHeading("Round 1"), "Preliminary")
        XCTAssertEqual(AuditionListParser.roundHeading("Semifinal:"), "Semi-final")
        XCTAssertEqual(AuditionListParser.roundHeading("II. Final round"), "Final")
        XCTAssertNil(AuditionListParser.roundHeading("Finale"))
        XCTAssertNil(AuditionListParser.roundHeading("Final: Concerto of your choice"))
        XCTAssertEqual(AuditionListParser.categoryHeading("Orchestral Excerpts:"), .excerpt)
        XCTAssertEqual(AuditionListParser.categoryHeading("Solo"), .solo)
        XCTAssertEqual(AuditionListParser.categoryHeading("Chamber music"), .chamber)
        XCTAssertNil(AuditionListParser.categoryHeading("Solo: Ein Lied"))
        XCTAssertEqual(AuditionListParser.stripListMarker("12) Holt: Ein Lied"), "Holt: Ein Lied")
        XCTAssertEqual(AuditionListParser.stripListMarker("(3) Holt"), "Holt")
        XCTAssertEqual(AuditionListParser.stripListMarker("a) Holt"), "Holt")
        XCTAssertEqual(AuditionListParser.stripListMarker("A. Quill: Ein Lied"), "A. Quill: Ein Lied", "initials are not list markers")
        XCTAssertEqual(AuditionListParser.stripListMarker("– Holt"), "Holt")
        XCTAssertTrue(AuditionListParser.isNoise("Page 2 of 3"))
        XCTAssertTrue(AuditionListParser.isNoise("- - -"))
        XCTAssertFalse(AuditionListParser.isNoise("Holt"))
        XCTAssertTrue(AuditionListParser.isContinuation("mm. 1–15"))
        XCTAssertTrue(AuditionListParser.isContinuation("2nd movement"))
        XCTAssertTrue(AuditionListParser.isContinuation("to letter B"))
        XCTAssertFalse(AuditionListParser.isContinuation("Holt: Ein Lied"))
        XCTAssertTrue(AuditionListParser.isSightReading("Sight reading"))
        XCTAssertTrue(AuditionListParser.isOwnChoice("One concerto of the candidate's choice"))
        XCTAssertFalse(AuditionListParser.isOwnChoice("Quill: Concerto, mvt. I"))

        let prefixed = AuditionListParser.analyzed(ParsedListItem(rawText: "Final: Concerto of your choice"))
        XCTAssertEqual(prefixed.round, "Final")
        XCTAssertNil(prefixed.composer)
        let solo = AuditionListParser.analyzed(ParsedListItem(rawText: "Solo: Holt Concerto in C, mvt. I"))
        XCTAssertEqual(solo.category, "solo")
        XCTAssertEqual(solo.composer, "Holt")
        XCTAssertEqual(solo.movementNumber, 1)
    }

    // MARK: - Matcher

    func testMatcherPrefersAgreeingNumbersAndMovements() throws {
        let pool = try makePool()
        let line = AuditionListParser.analyzed(ParsedListItem(rawText: "Quill – Symphony No. 2, mvt. II, mm. 1–15"))
        let candidates = AuditionListMatcher.candidates(for: line, in: pool)
        XCTAssertEqual(candidates.first?.excerptId, "cello-quill-symphony-2-mvt2")
        XCTAssertGreaterThanOrEqual(candidates.first!.score, AuditionListMatcher.strongThreshold)
        XCTAssertEqual(AuditionListMatcher.preselected(candidates), "cello-quill-symphony-2-mvt2")
        // Symphony No. 3 shares every word but not the number: it must score far lower.
        let third = AuditionListMatcher.score(item: line, excerpt: pool[1])
        XCTAssertLessThan(third, 0.3)
    }

    func testMatcherShortFormsAndTitles() throws {
        let pool = try makePool()
        let short = AuditionListParser.analyzed(ParsedListItem(rawText: "Reine Sym. 2/II"))
        let shortCandidates = AuditionListMatcher.candidates(for: short, in: pool)
        XCTAssertEqual(shortCandidates.first?.excerptId, "cello-reine-symphony-2-mvt2")
        XCTAssertGreaterThanOrEqual(shortCandidates.first!.score, AuditionListMatcher.strongThreshold)
        XCTAssertLessThan(AuditionListMatcher.score(item: short, excerpt: pool[3]), AuditionListMatcher.score(item: short, excerpt: pool[2]))

        let scherzo = AuditionListParser.analyzed(ParsedListItem(rawText: "Reine: Symphony No. 2, Scherzo"))
        XCTAssertEqual(AuditionListMatcher.candidates(for: scherzo, in: pool).first?.excerptId, "cello-reine-symphony-2-mvt3")

        let lied = AuditionListParser.analyzed(ParsedListItem(rawText: "Holt: Ein Lied"))
        let liedCandidates = AuditionListMatcher.candidates(for: lied, in: pool)
        XCTAssertEqual(liedCandidates.first?.excerptId, "cello-holt-ein-lied-opening")
        XCTAssertGreaterThanOrEqual(liedCandidates.first!.score, AuditionListMatcher.strongThreshold)
    }

    func testMatcherTiesAreNeverPreselected() throws {
        let pool = try makePool()
        let vague = AuditionListParser.analyzed(ParsedListItem(rawText: "Reine Symphony"))
        let candidates = AuditionListMatcher.candidates(for: vague, in: pool)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(Set(candidates.prefix(2).map { $0.excerptId }), Set(["cello-reine-symphony-2-mvt2", "cello-reine-symphony-2-mvt3"]))
        XCTAssertEqual(candidates[0].score, candidates[1].score)
        XCTAssertLessThan(candidates[0].score, AuditionListMatcher.strongThreshold)
        XCTAssertLessThan(candidates[2].score, candidates[1].score, "a work match without the composer is weaker")
        XCTAssertNil(AuditionListMatcher.preselected(candidates))
        XCTAssertTrue(AuditionListMatcher.isStrong(0.45 + 0.35 + 0.1))

        let unrelated = AuditionListParser.analyzed(ParsedListItem(rawText: "Sight-reading"))
        XCTAssertTrue(AuditionListMatcher.candidates(for: unrelated, in: pool).isEmpty)
        XCTAssertEqual(AuditionListMatcher.percentText(0.856), "86%")
        XCTAssertEqual(AuditionListMatcher.percentText(1.4), "100%")
        XCTAssertEqual(AuditionListMatcher.numbers(in: "Symphony No. 2 in D major, Op. 11"), Set([2, 11]))
    }

    func testReviewLinesAndItems() throws {
        let pool = try makePool()
        let parsed = AuditionListParser.parse(text: """
        Preliminary round
        Quill: Symphony No. 2, mvt. II
        Reine Symphony
        Sight-reading
        """)
        var lines = AuditionReviewLogic.lines(from: parsed, pool: pool)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].chosenExcerptId, "cello-quill-symphony-2-mvt2")
        XCTAssertNil(lines[1].chosenExcerptId, "a tie is proposed, not pre-ticked")
        XCTAssertEqual(lines[1].candidates.count, 3)
        XCTAssertTrue(lines[2].candidates.isEmpty)
        XCTAssertEqual(AuditionReviewLogic.includedCount(lines), 3)

        lines[1].include = false
        lines[0].text = "Quill: Symphony No. 3, mvt. III"
        lines[0] = AuditionReviewLogic.rematched(lines[0], pool: pool)
        XCTAssertNil(lines[0].chosenExcerptId, "the old link no longer fits the edited words")
        XCTAssertEqual(lines[0].candidates.first?.excerptId, "cello-quill-symphony-3-mvt3")

        let auditionId = UUID()
        let items = AuditionReviewLogic.items(from: lines, auditionId: auditionId, startOrder: 4)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0.order }, [4, 5])
        XCTAssertEqual(items[0].rawText, "Quill: Symphony No. 3, mvt. III")
        XCTAssertEqual(items[0].round, "Preliminary")
        XCTAssertNil(items[0].excerptId)
        XCTAssertEqual(items[1].category, "sight_reading")
        XCTAssertTrue(items.allSatisfy { $0.auditionId == auditionId })
    }

    // MARK: - Building from the feed

    @MainActor
    func testAuditionBuiltFromVacancyKeepsOnlyParsedFacts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vacancy = makeVacancy()
        let audition = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: .horn, context: context, calendar: calendar)
        XCTAssertEqual(audition.orchestra, "Example Philharmonic")
        XCTAssertEqual(audition.position, "Section cello")
        XCTAssertEqual(audition.instrument, .cello)
        XCTAssertEqual(audition.applicationDeadline, day(2026, 11, 3))
        XCTAssertEqual(audition.auditionDate, day(2026, 11, 20))
        XCTAssertEqual(audition.vacancyId, "vac-1")
        XCTAssertEqual(audition.sourceURL, "https://example.org/auditions/cello.pdf")
        XCTAssertEqual(audition.listCompleteness, "full")
        XCTAssertFalse(audition.remindersEnabled)

        let items = AuditionsStore.items(for: audition.id, context: context)
        XCTAssertEqual(items.count, 3, "blank lines are skipped")
        XCTAssertEqual(items.map { $0.order }, [0, 1, 2])
        XCTAssertEqual(items[0].rawText, "Quill: Symphony No. 2, mvt. II")
        XCTAssertEqual(items[0].excerptId, "cello-quill-symphony-2-mvt2")
        XCTAssertEqual(items[0].round, "Preliminary")
        XCTAssertEqual(items[1].category, "solo")
        XCTAssertNil(items[2].excerptId, "a blank excerpt id is no match")

        // Preparing the same vacancy again opens the existing audition instead of making a second one.
        let again = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: .horn, context: context, calendar: calendar)
        XCTAssertEqual(again.id, audition.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Audition>()).count, 1)
    }

    @MainActor
    func testVacancyWithoutDatesLeavesThemEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vacancy = makeVacancy(id: "vac-2", deadline: nil, auditionDates: ["to be announced"], completeness: "revealed_on_invitation", items: [])
        let audition = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: .cello, context: context, calendar: calendar)
        XCTAssertNil(audition.applicationDeadline)
        XCTAssertNil(audition.auditionDate)
        XCTAssertEqual(ListCompleteness(raw: audition.listCompleteness), .revealedOnInvitation)
        XCTAssertTrue(AuditionsStore.items(for: audition.id, context: context).isEmpty)
    }

    @MainActor
    func testStoreAppendsAddsAndMoves() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let pool = try makePool()
        let audition = Audition(orchestra: "Example Philharmonic", position: "Section cello", instrument: .cello)
        context.insert(audition)
        try context.save()

        XCTAssertTrue(try AuditionsStore.add(excerpt: pool[0], to: audition, context: context))
        XCTAssertFalse(try AuditionsStore.add(excerpt: pool[0], to: audition, context: context), "no duplicates")
        try AuditionsStore.add(text: "  Holt: Ein Lied  ", round: "final", category: .excerpt, excerptId: "", to: audition, context: context)
        try AuditionsStore.append([AuditionItem(auditionId: UUID(), order: 99, rawText: "Sight-reading")], to: audition, context: context)

        var items = AuditionsStore.items(for: audition.id, context: context)
        XCTAssertEqual(items.map { $0.rawText }, ["Quill · Symphony No. 2 in D major — Mvt. II · Opening", "Holt: Ein Lied", "Sight-reading"])
        XCTAssertEqual(items.map { $0.order }, [0, 1, 2])
        XCTAssertEqual(items[1].round, "Final")
        XCTAssertNil(items[1].excerptId)
        XCTAssertEqual(items[2].auditionId, audition.id, "appended items are re-homed to the audition")
        XCTAssertEqual(AuditionsStore.nextOrder(for: audition.id, context: context), 3)

        AuditionsStore.move(items, from: IndexSet(integer: 2), to: 0, context: context)
        items = AuditionsStore.items(for: audition.id, context: context)
        XCTAssertEqual(items.map { $0.rawText }, ["Sight-reading", "Quill · Symphony No. 2 in D major — Mvt. II · Opening", "Holt: Ein Lied"])

        AuditionsStore.delete(items[0], context: context)
        XCTAssertEqual(AuditionsStore.items(for: audition.id, context: context).count, 2)
        AuditionsStore.delete(audition, context: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AuditionItem>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Audition>()).isEmpty)
    }

    // MARK: - Archive (PLAN F5)

    @MainActor
    func testArchiveKeepsTheListAndRestoreBringsItBack() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let pool = try makePool()
        let keep = Audition(orchestra: "Example Philharmonic", position: "Section cello", instrument: .cello)
        let gone = Audition(orchestra: "Example Sinfonietta", position: "Principal cello", instrument: .cello)
        gone.remindersEnabled = true
        context.insert(keep)
        context.insert(gone)
        try context.save()
        XCTAssertTrue(try AuditionsStore.add(excerpt: pool[0], to: gone, context: context))

        XCTAssertFalse(gone.isArchived)
        XCTAssertNil(gone.archivedAt, "new auditions are active")
        try AuditionsStore.archive(gone, context: context, now: day(2026, 10, 11))
        XCTAssertTrue(gone.isArchived)
        XCTAssertEqual(gone.archivedAt, day(2026, 10, 11))
        XCTAssertTrue(gone.remindersEnabled, "the choice is kept so Restore can set the reminders again")
        XCTAssertEqual(AuditionsStore.activeAuditions(context: context).map { $0.id }, [keep.id])
        XCTAssertEqual(AuditionsStore.archivedAuditions(context: context).map { $0.id }, [gone.id])
        XCTAssertEqual(AuditionsStore.items(for: gone.id, context: context).count, 1, "the list stays with the archived audition")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Audition>()).count, 2, "archiving deletes nothing")

        try AuditionsStore.restore(gone, context: context)
        XCTAssertFalse(gone.isArchived)
        XCTAssertNil(gone.archivedAt)
        XCTAssertEqual(AuditionsStore.activeAuditions(context: context).count, 2)
        XCTAssertTrue(AuditionsStore.archivedAuditions(context: context).isEmpty)
        XCTAssertEqual(AuditionsStore.items(for: gone.id, context: context).count, 1)

        // "Delete for good" from the archive removes the audition and its list.
        try AuditionsStore.archive(gone, context: context)
        AuditionsStore.delete(gone, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Audition>()).map { $0.id }, [keep.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<AuditionItem>()).isEmpty)
    }

    @MainActor
    func testPrepareRestoresAnArchivedAuditionInsteadOfDuplicating() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vacancy = makeVacancy()
        let first = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: .horn, context: context, calendar: calendar)
        first.remindersEnabled = true
        try AuditionsStore.archive(first, context: context)
        XCTAssertNil(AuditionsStore.activeAudition(vacancyId: "vac-1", context: context), "the feed button reads Prepare again")
        XCTAssertEqual(AuditionsStore.audition(vacancyId: "vac-1", context: context)?.id, first.id, "archived ones still count for de-duplication")

        let again = try AuditionsStore.prepare(from: vacancy, fallbackInstrument: .horn, context: context, calendar: calendar)
        XCTAssertEqual(again.id, first.id)
        XCTAssertFalse(again.isArchived, "Prepare restores the archived audition")
        XCTAssertTrue(again.remindersEnabled, "the caller reschedules the reminders")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Audition>()).count, 1, "no second audition for the same vacancy")
        XCTAssertEqual(AuditionsStore.items(for: again.id, context: context).count, 3, "the old list is kept, not rebuilt")
        XCTAssertEqual(AuditionsStore.activeAudition(vacancyId: "vac-1", context: context)?.id, first.id)
        XCTAssertNil(AuditionsStore.audition(vacancyId: "vac-nobody", context: context))
    }

    func testArchivedRowAndOrdering() {
        XCTAssertFalse(AuditionArchive.showsArchivedRow(count: 0), "hidden while nothing is archived")
        XCTAssertTrue(AuditionArchive.showsArchivedRow(count: 1))
        XCTAssertEqual(AuditionArchive.archivedRowTitle(count: 3), "Archived (3)")

        let older = Audition(orchestra: "Example Philharmonic", position: "", instrument: .cello)
        older.archivedAt = day(2026, 10, 1)
        let newer = Audition(orchestra: "Example Sinfonietta", position: "", instrument: .cello)
        newer.archivedAt = day(2026, 10, 5)
        XCTAssertEqual(AuditionArchive.archivedFirst([older, newer]).map { $0.id }, [newer.id, older.id], "most recently archived first")
        XCTAssertTrue(AuditionArchive.archivedFirst([]).isEmpty)
    }

    func testItemTitleAndMockItems() throws {
        let pool = try makePool()
        XCTAssertEqual(AuditionBuilder.itemTitle(for: pool[4]), "Holt · Ein Lied — Opening")
        let sources: [AuditionMockLogic.Source] = [
            AuditionMockLogic.Source(rawText: "Quill: Symphony No. 2", excerptId: "cello-quill-symphony-2-mvt2", category: "excerpt",
                                     excerptTitle: "Quill · Symphony No. 2 in D major — Mvt. II · Opening"),
            AuditionMockLogic.Source(rawText: "Sight-reading", excerptId: nil, category: "sight_reading", excerptTitle: nil),
            AuditionMockLogic.Source(rawText: "A concerto of your choice", excerptId: nil, category: "solo", excerptTitle: nil),
        ]
        let mock = AuditionMockLogic.mockItems(sources)
        XCTAssertEqual(mock.map { $0.title }, ["Quill · Symphony No. 2 in D major — Mvt. II · Opening", "A concerto of your choice"])
        XCTAssertEqual(mock[0].excerptId, "cello-quill-symphony-2-mvt2")
        XCTAssertNil(mock[1].excerptId)
    }
}
