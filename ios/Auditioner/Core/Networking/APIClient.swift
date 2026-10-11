import Foundation

// Contract with backend/ (FastAPI). See backend/README.md.
//   POST /v1/omr       multipart: image (JPEG), instrument, transposition, meter?, hints (JSON array of OCR lines)
//                      → OMRResponse
//   POST /v1/identify  JSON {ocrText, instrument} → {candidates: [{excerptId, score}]}
//   POST /v1/feedback  JSON {context, excerptId?, message, appVersion} → 201 {"status":"received"}
//                      (503 when feedback storage isn't set up on the server; the app keeps the report queued)
//   GET  /v1/auditions?instrument=&region=   → {auditions: [FeedVacancy]} (published only)
//   GET  /v1/recommendations?instrument=&position=&region= → {recommendations: [Recommendation]}
//   GET  /healthz      → {"status":"ok"}
// Every request carries X-Device-Id (random per install) and X-App-Version.

struct OMRResponse: Decodable {
    var musicxml: String
    var warnings: [String]
    var engine: String
    var measures: Int?
}

struct IdentifyCandidate: Decodable, Hashable {
    var excerptId: String
    var score: Double
}

/// A published open audition from the feed (orchestras' own pages, reviewed by Milai).
struct FeedVacancy: Decodable, Hashable, Identifiable {
    var id: String
    var orchestra: String
    var orchestraId: String?
    var region: String?
    var position: String
    var instrument: String
    var applicationDeadline: String?   // yyyy-MM-dd
    var auditionDates: [String]
    var listCompleteness: String       // full | partial_public | works_only | revealed_on_invitation
    var sourceURL: String
    var lastCheckedAt: String?         // ISO date
    var items: [FeedVacancyItem]
}

struct FeedVacancyItem: Decodable, Hashable {
    var rawText: String
    var category: String
    var round: String
    var excerptId: String?
}

/// "What orchestras ask" for one excerpt, computed on the server from published lists.
struct Recommendation: Decodable, Hashable {
    var excerptId: String
    var tier: String          // core | common | occasional
    var share: Double         // 0...1 recency-weighted share of lists
    var listCount: Int        // lists that include it
    var totalLists: Int       // lists considered
    var openNow: Int          // open auditions listing it now
    var evidence: String      // plain-words summary, e.g. "asked in 68% of 41 section cello lists, 2023–2026"
}

private struct AuditionsResponse: Decodable { var auditions: [FeedVacancy] }
private struct RecommendationsResponse: Decodable { var recommendations: [Recommendation] }

private struct IdentifyResponse: Decodable {
    var candidates: [IdentifyCandidate]
}

enum APIError: LocalizedError {
    case notConfigured
    case server(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "The Auditioner server isn't set up yet. Add its address in Settings → Server.")
        case .server(let status, let message):
            if status == 429 { return String(localized: "Daily scan limit reached. Try again tomorrow.") }
            return message.isEmpty ? String(localized: "The server couldn't read this page (error \(status)).") : message
        case .invalidResponse:
            return String(localized: "The server sent an answer the app didn't understand.")
        }
    }
}

final class APIClient {
    let baseURL: URL?
    let deviceId: String
    let session: URLSession

    init(baseURL: URL?, deviceId: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceId = deviceId
        self.session = session
    }

    static func fromSettings(_ settings: AppSettings = .shared) -> APIClient {
        APIClient(baseURL: settings.serverBaseURL, deviceId: settings.deviceId)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let baseURL else { throw APIError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
        req.timeoutInterval = 120
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
        return data
    }

    func health() async -> Bool {
        guard let req = try? request(path: "healthz", method: "GET"),
              let _ = try? await send(req) else { return false }
        return true
    }

    func recognize(imageJPEG: Data, instrument: Instrument, transposition: Int, meter: String?, hints: [String]) async throws -> OMRResponse {
        var req = try request(path: "v1/omr", method: "POST")
        let boundary = "auditioner-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("instrument", instrument.rawValue)
        field("transposition", String(transposition))
        if let meter { field("meter", meter) }
        let hintsJSON = (try? JSONEncoder().encode(hints)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        field("hints", hintsJSON)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"page.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(imageJPEG)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let data = try await send(req)
        do {
            return try JSONDecoder().decode(OMRResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Sends one "Report an error" / feedback message. Throws `APIError` on failure so the caller can keep it queued.
    func sendFeedback(context: String, excerptId: String?, message: String) async throws {
        var req = try request(path: "v1/feedback", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["context": context, "message": message, "appVersion": appVersion]
        if let excerptId { body["excerptId"] = excerptId }
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await send(req)
    }

    func auditions(instrument: Instrument, region: String?) async throws -> [FeedVacancy] {
        var req = try request(path: "v1/auditions", method: "GET")
        req.url = Self.withQuery(req.url, ["instrument": instrument.rawValue, "region": region])
        let data = try await send(req)
        do { return try JSONDecoder().decode(AuditionsResponse.self, from: data).auditions }
        catch { throw APIError.invalidResponse }
    }

    func recommendations(instrument: Instrument, position: Position, region: String?) async throws -> [Recommendation] {
        var req = try request(path: "v1/recommendations", method: "GET")
        req.url = Self.withQuery(req.url, ["instrument": instrument.rawValue, "position": position.rawValue, "region": region])
        let data = try await send(req)
        do { return try JSONDecoder().decode(RecommendationsResponse.self, from: data).recommendations }
        catch { throw APIError.invalidResponse }
    }

    static func withQuery(_ url: URL?, _ items: [String: String?]) -> URL? {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        return comps.url
    }

    func identify(ocrText: String, instrument: Instrument) async throws -> [IdentifyCandidate] {
        var req = try request(path: "v1/identify", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["ocrText": ocrText, "instrument": instrument.rawValue])
        let data = try await send(req)
        do {
            return try JSONDecoder().decode(IdentifyResponse.self, from: data).candidates
        } catch {
            throw APIError.invalidResponse
        }
    }
}
