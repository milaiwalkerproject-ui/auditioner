import Foundation

// Community practice trends — "Popular with cello players" (PLAN D6). Contract with backend/app/trends.py:
//   POST   /v1/trends               JSON {instrument, week: "YYYY-Www" (this or last ISO week, UTC), excerptIds: [≤ 50]} → 204
//   DELETE /v1/trends               → 204 (everything this device shared is deleted)
//   GET    /v1/trends?instrument=   → TrendsResponse (tiers only — the server never sends counts or shares)
// Every request carries X-Device-Id (see APIClient.request); the server stores only a keyed hash of it.

/// The server's answer to GET /v1/trends.
struct TrendsResponse: Decodable, Hashable {
    var enough: Bool
    var fromWeek: String
    var toWeek: String
    var trends: [TrendsResponseEntry]
}

struct TrendsResponseEntry: Decodable, Hashable {
    var excerptId: String
    var tier: String          // "very-popular" | "popular"
}

/// What the trends feature needs from the network, so tests can plug in a fake.
protocol TrendsAPI {
    /// False when no server address is set (requests would fail with `APIError.notConfigured`).
    var isConfigured: Bool { get }
    func shareTrends(instrument: Instrument, week: String, excerptIds: [String]) async throws
    func forgetTrends() async throws
    func trends(instrument: Instrument) async throws -> TrendsResponse
}

private struct TrendsShareBody: Encodable {
    var instrument: String
    var week: String
    var excerptIds: [String]
}

extension APIClient: TrendsAPI {
    var isConfigured: Bool { baseURL != nil }

    /// Replaces this device's row for `instrument` + `week` with `excerptIds` (catalogue ids only; the server drops the rest).
    func shareTrends(instrument: Instrument, week: String, excerptIds: [String]) async throws {
        var req: URLRequest = try request(path: "v1/trends", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = TrendsShareBody(instrument: instrument.rawValue, week: week, excerptIds: excerptIds)
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await send(req)
    }

    /// Deletes everything this device shared (the player turned sharing off).
    func forgetTrends() async throws {
        let req: URLRequest = try request(path: "v1/trends", method: "DELETE")
        _ = try await send(req)
    }

    func trends(instrument: Instrument) async throws -> TrendsResponse {
        var req: URLRequest = try request(path: "v1/trends", method: "GET")
        req.url = APIClient.withQuery(req.url, ["instrument": instrument.rawValue])
        let data: Data = try await send(req)
        do {
            return try JSONDecoder().decode(TrendsResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
