import Foundation
import SwiftData

/// Sends "Report an error" / "Send feedback" messages (`FeedbackReport`) and resends the ones
/// that couldn't go out — no server address yet, no network, server down — the next time the
/// app starts or comes back to the front (`FeedbackQueueFlusher`).
///
/// A report is saved on the device before the first attempt, so nothing the player wrote is lost.
enum FeedbackQueue {
    /// How many queued reports one flush sends at most (oldest first).
    static let maxPerFlush: Int = 20

    enum Outcome: Equatable {
        /// The server took it.
        case sent
        /// Kept on the device; tried again at the next flush.
        case queued

        var title: String {
            switch self {
            case .sent: return String(localized: "Thanks")
            case .queued: return String(localized: "Saved")
            }
        }

        var text: String {
            switch self {
            case .sent:
                return String(localized: "Your message was sent. Thank you for helping us get this right.")
            case .queued:
                return String(localized: "Saved — it will be sent when the app can reach our server.")
            }
        }
    }

    // MARK: Pure logic (tested)

    /// Which items to send now: the unsent ones, oldest first, at most `limit`.
    static func pickUnsent<T>(_ items: [T], limit: Int = FeedbackQueue.maxPerFlush,
                              isSent: (T) -> Bool, createdAt: (T) -> Date) -> [T] {
        let unsent: [T] = items.filter { !isSent($0) }
        let ordered: [T] = unsent.sorted { createdAt($0) < createdAt($1) }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// Short code stored in `FeedbackReport.lastError` — never anything personal.
    static func errorText(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .notConfigured: return "no-server"
            case .server(let status, _): return "server-\(status)"
            case .invalidResponse: return "bad-response"
            }
        }
        if let urlError = error as? URLError {
            return "network-\(urlError.code.rawValue)"
        }
        return "failed"
    }

    /// After this error, is it worth trying the next report in the same flush? Only when the server
    /// refused this one report (a 4xx other than 429); no server, no network, 429 and 5xx stop the flush.
    static func shouldContinue(after error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .server(let status, _):
            return status >= 400 && status < 500 && status != 429
        case .notConfigured, .invalidResponse:
            return false
        }
    }

    // MARK: Sending

    /// Tries to send one report and records the result on it (`sentAt`, or `lastError`).
    /// Returns the error when it failed. The caller saves the context.
    @MainActor
    @discardableResult
    static func attempt(_ report: FeedbackReport, client: APIClient) async -> Error? {
        do {
            try await client.sendFeedback(context: report.context, excerptId: report.excerptId, message: report.message)
            report.sentAt = Date()
            report.lastError = nil
            return nil
        } catch {
            report.lastError = errorText(error)
            return error
        }
    }

    /// One report, from the sheet: sent, or queued for later.
    @MainActor
    static func send(_ report: FeedbackReport, client: APIClient) async -> Outcome {
        let error: Error? = await attempt(report, client: client)
        return error == nil ? .sent : .queued
    }

    @MainActor private static var isFlushing: Bool = false

    /// Resends queued reports, oldest first, at most `maxPerFlush`. Safe to call often: it does
    /// nothing while another flush is running or while no server address is set.
    @MainActor
    static func flush(context: ModelContext, client: APIClient? = nil) async {
        if isFlushing { return }
        isFlushing = true
        defer { isFlushing = false }

        let descriptor = FetchDescriptor<FeedbackReport>()
        let all: [FeedbackReport] = (try? context.fetch(descriptor)) ?? []
        let pending: [FeedbackReport] = pickUnsent(all, isSent: { $0.sentAt != nil }, createdAt: { $0.createdAt })
        guard !pending.isEmpty else { return }

        let api: APIClient = client ?? APIClient.fromSettings()
        guard api.baseURL != nil else { return }

        for report in pending {
            if let error = await attempt(report, client: api) {
                if !shouldContinue(after: error) { break }
            }
        }
        try? context.save()
    }
}
