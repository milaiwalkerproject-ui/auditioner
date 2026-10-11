import XCTest
import SwiftData
@testable import Auditioner

final class FeedbackTests: XCTestCase {

    // MARK: Message trimming and limits

    func testCleanMessageTrimsAndCuts() {
        XCTAssertEqual(FeedbackLogic.cleanMessage("  The bar numbers are off \n"), "The bar numbers are off")
        XCTAssertEqual(FeedbackLogic.cleanMessage("   \n\t "), "")
        let long = String(repeating: "a", count: 2500)
        XCTAssertEqual(FeedbackLogic.cleanMessage(long).count, FeedbackLogic.maxMessageLength)
        XCTAssertEqual(FeedbackLogic.cleanMessage("  " + long).count, FeedbackLogic.maxMessageLength)
    }

    func testCanSendNeedsRealText() {
        XCTAssertFalse(FeedbackLogic.canSend(""))
        XCTAssertFalse(FeedbackLogic.canSend("  \n"))
        XCTAssertTrue(FeedbackLogic.canSend(" ok "))
    }

    func testClampWhileTypingAndCounter() {
        let long = String(repeating: "x", count: 2001)
        XCTAssertEqual(FeedbackLogic.clamped("abc"), "abc")
        XCTAssertEqual(FeedbackLogic.clamped(long).count, 2000)
        XCTAssertEqual(FeedbackLogic.counterText(""), "0/2000")
        XCTAssertEqual(FeedbackLogic.counterText("abc"), "3/2000")
        XCTAssertEqual(FeedbackLogic.counterText(long), "2000/2000")
    }

    // MARK: Context formatting (server contract: a-z 0-9 : - , max 64)

    func testCleanContextMatchesServerRules() {
        XCTAssertEqual(FeedbackLogic.cleanContext("excerpt-note:practiceTips"), "excerpt-note:practicetips")
        XCTAssertEqual(FeedbackLogic.cleanContext("Settings"), "settings")
        XCTAssertEqual(FeedbackLogic.cleanContext("has space/slash_underscore!"), "hasspaceslashunderscore")
        XCTAssertEqual(FeedbackLogic.cleanContext(""), "app")
        XCTAssertEqual(FeedbackLogic.cleanContext("***"), "app")
        XCTAssertEqual(FeedbackLogic.cleanContext(String(repeating: "x", count: 100)).count, 64)
        XCTAssertEqual(FeedbackLogic.cleanContext("mock-audition:timer"), "mock-audition:timer")
    }

    func testCleanExcerptId() {
        XCTAssertNil(FeedbackLogic.cleanExcerptId(nil))
        XCTAssertNil(FeedbackLogic.cleanExcerptId("   "))
        XCTAssertEqual(FeedbackLogic.cleanExcerptId(" cello-x "), "cello-x")
        XCTAssertEqual(FeedbackLogic.cleanExcerptId(String(repeating: "e", count: 300))?.count, 128)
    }

    func testTitleDependsOnContext() {
        XCTAssertEqual(FeedbackLogic.title(for: "excerpt-note:pitfalls"), "Report an error")
        XCTAssertEqual(FeedbackLogic.title(for: "excerpt-fact"), "Report an error")
        XCTAssertEqual(FeedbackLogic.title(for: "Excerpt-Recording"), "Report an error")
        XCTAssertEqual(FeedbackLogic.title(for: "settings"), "Send feedback")
        XCTAssertEqual(FeedbackLogic.title(for: "scan"), "Send feedback")
        XCTAssertEqual(FeedbackLogic.title(for: ""), "Send feedback")
    }

    func testContextDescriptions() {
        XCTAssertEqual(FeedbackLogic.contextDescription("excerpt-note:history"), "Excerpt notes — History")
        XCTAssertEqual(FeedbackLogic.contextDescription("excerpt-note:pitfalls"), "Excerpt notes — Common pitfalls")
        XCTAssertEqual(FeedbackLogic.contextDescription("excerpt-note:practiceTips"), "Excerpt notes — Practice tips")
        XCTAssertEqual(FeedbackLogic.contextDescription("excerpt-fact"), "Excerpt facts")
        XCTAssertEqual(FeedbackLogic.contextDescription("settings"), "General feedback")
        XCTAssertEqual(FeedbackLogic.contextDescription("mock-audition:timer"), "Mock audition timer")
        XCTAssertEqual(FeedbackLogic.humanize("record-compare"), "Record compare")
    }

    // MARK: Queue selection

    private struct Item {
        let id: Int
        let created: Date
        let sent: Bool
    }

    func testPickUnsentOldestFirstCapped() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var items: [Item] = []
        for i in 0..<30 {
            // Higher id = created earlier; every third one is already sent.
            items.append(Item(id: i, created: base.addingTimeInterval(Double(30 - i)), sent: i % 3 == 0))
        }
        let picked = FeedbackQueue.pickUnsent(items, isSent: { $0.sent }, createdAt: { $0.created })
        XCTAssertEqual(picked.count, FeedbackQueue.maxPerFlush)
        XCTAssertTrue(picked.allSatisfy { !$0.sent })
        XCTAssertEqual(picked.map { $0.created }, picked.map { $0.created }.sorted())
        XCTAssertEqual(picked.first?.id, 29)

        let small = FeedbackQueue.pickUnsent(items, limit: 3, isSent: { $0.sent }, createdAt: { $0.created })
        XCTAssertEqual(small.map { $0.id }, [29, 28, 26])

        let none = FeedbackQueue.pickUnsent(items, limit: 0, isSent: { $0.sent }, createdAt: { $0.created })
        XCTAssertTrue(none.isEmpty)
        let allSent = FeedbackQueue.pickUnsent(items, isSent: { _ in true }, createdAt: { $0.created })
        XCTAssertTrue(allSent.isEmpty)
    }

    func testErrorTextAndContinuation() {
        XCTAssertEqual(FeedbackQueue.errorText(APIError.notConfigured), "no-server")
        XCTAssertEqual(FeedbackQueue.errorText(APIError.server(status: 503, message: "x")), "server-503")
        XCTAssertEqual(FeedbackQueue.errorText(APIError.invalidResponse), "bad-response")
        XCTAssertEqual(FeedbackQueue.errorText(URLError(.notConnectedToInternet)),
                       "network-\(URLError.Code.notConnectedToInternet.rawValue)")

        XCTAssertFalse(FeedbackQueue.shouldContinue(after: APIError.notConfigured))
        XCTAssertFalse(FeedbackQueue.shouldContinue(after: APIError.server(status: 429, message: "")))
        XCTAssertFalse(FeedbackQueue.shouldContinue(after: APIError.server(status: 503, message: "")))
        XCTAssertTrue(FeedbackQueue.shouldContinue(after: APIError.server(status: 422, message: "")))
        XCTAssertTrue(FeedbackQueue.shouldContinue(after: APIError.server(status: 400, message: "")))
        XCTAssertFalse(FeedbackQueue.shouldContinue(after: URLError(.timedOut)))
    }

    // MARK: Sending without a server keeps the report queued

    @MainActor
    func testSendAndFlushWithoutServerKeepReportsQueued() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FeedbackReport.self, configurations: configuration)
        let context = ModelContext(container)

        let older = FeedbackReport(context: "settings", excerptId: nil, message: "older")
        older.createdAt = Date(timeIntervalSince1970: 1_000)
        let alreadySent = FeedbackReport(context: "excerpt-fact", excerptId: "cello-x", message: "sent")
        alreadySent.sentAt = Date()
        context.insert(older)
        context.insert(alreadySent)
        try context.save()

        let client = APIClient(baseURL: nil, deviceId: "test-device")
        let outcome: FeedbackQueue.Outcome = await FeedbackQueue.send(older, client: client)
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(older.lastError, "no-server")
        XCTAssertNil(older.sentAt)
        XCTAssertEqual(FeedbackQueue.Outcome.queued.text, "Saved — it will be sent when the app can reach our server.")

        await FeedbackQueue.flush(context: context, client: client)
        let all = try context.fetch(FetchDescriptor<FeedbackReport>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter { $0.sentAt == nil }.count, 1)
        XCTAssertNotNil(alreadySent.sentAt)
    }
}
