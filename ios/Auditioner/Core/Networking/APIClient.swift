import Foundation

// Contract with backend/ (FastAPI). See backend/README.md.
//   POST /v1/omr       multipart: image (JPEG), instrument, transposition, meter?, hints (JSON array of OCR lines)
//                      → OMRResponse
//   POST /v1/identify  JSON {ocrText, instrument} → {candidates: [{excerptId, score}]}
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
