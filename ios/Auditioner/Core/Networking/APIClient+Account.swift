import Foundation

// Account endpoints (PLAN B2: Sign in with Apple, optional). See backend/app/accounts_api.py.
//   POST   /v1/account/apple    JSON {identityToken, authorizationCode, nonce} → AppleSignInResponse
//   GET    /v1/account          Bearer → AccountInfo
//   POST   /v1/account/signout  Bearer → 204 (this session only)
//   DELETE /v1/account          Bearer → 204 (Apple token revoked, account and sessions deleted)
// Errors are {"detail": "<plain words>"}: 400 Apple couldn't confirm the sign-in, 401 signed out,
// 502 Apple or the account store didn't answer, 503 accounts aren't set up on the server.
// Every request still carries X-Device-Id and X-App-Version. `request(path:method:)` never reads the
// keychain; these methods set the Bearer header explicitly from their argument (`AccountStore` passes
// the stored token), and the sign-in exchange carries no session at all.

/// Answer to a successful Sign in with Apple exchange.
struct AppleSignInResponse: Decodable, Equatable {
    var accountId: String
    var sessionToken: String
    var dailyScanLimit: Int
}

/// The signed-in account as the server sees it.
struct AccountInfo: Decodable, Equatable {
    var accountId: String
    var dailyScanLimit: Int
    var createdAt: String   // yyyy-MM-dd
}

/// The four account calls, as a protocol so `AccountStore` can be tested with a fake server.
protocol AccountAPI {
    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String) async throws -> AppleSignInResponse
    func account(sessionToken: String) async throws -> AccountInfo
    func signOut(sessionToken: String) async throws
    func deleteAccount(sessionToken: String) async throws
}

extension APIClient: AccountAPI {
    private struct AppleSignInBody: Encodable {
        var identityToken: String
        var authorizationCode: String
        var nonce: String
    }

    /// A plain request with this session token as `Authorization: Bearer …`.
    private func request(path: String, method: String, sessionToken: String) throws -> URLRequest {
        var req: URLRequest = try request(path: path, method: method)
        req.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        return req
    }

    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String) async throws -> AppleSignInResponse {
        // A plain request: a stale token from an earlier sign-in must not ride along on a fresh one.
        var req: URLRequest = try request(path: "v1/account/apple", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AppleSignInBody(identityToken: identityToken,
                                                                 authorizationCode: authorizationCode,
                                                                 nonce: nonce))
        let data: Data = try await send(req)
        do {
            return try JSONDecoder().decode(AppleSignInResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    func account(sessionToken: String) async throws -> AccountInfo {
        let req: URLRequest = try request(path: "v1/account", method: "GET", sessionToken: sessionToken)
        let data: Data = try await send(req)
        do {
            return try JSONDecoder().decode(AccountInfo.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    func signOut(sessionToken: String) async throws {
        let req: URLRequest = try request(path: "v1/account/signout", method: "POST", sessionToken: sessionToken)
        _ = try await send(req)
    }

    func deleteAccount(sessionToken: String) async throws {
        let req: URLRequest = try request(path: "v1/account", method: "DELETE", sessionToken: sessionToken)
        _ = try await send(req)
    }
}
