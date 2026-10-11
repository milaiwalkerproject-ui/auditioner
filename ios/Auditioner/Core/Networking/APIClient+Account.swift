import Foundation

// Account endpoints (PLAN B2: Sign in with Apple, optional). See backend/app/accounts_api.py.
//   POST   /v1/account/apple    JSON {identityToken, authorizationCode, nonce} → AppleSignInResponse
//   GET    /v1/account          Bearer → AccountInfo
//   POST   /v1/account/signout  Bearer → 204 (this session only)
//   DELETE /v1/account          Bearer → 204 (Apple token revoked, account and sessions deleted)
// Errors are {"detail": "<plain words>"}: 400 Apple couldn't confirm the sign-in, 401 signed out,
// 502 Apple or the account store didn't answer, 503 accounts aren't set up on the server.
// Every request still carries X-Device-Id and X-App-Version; `request(path:method:)` adds the
// Bearer token from the keychain on its own, these methods set it explicitly from their argument.

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

    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String) async throws -> AppleSignInResponse {
        var req: URLRequest = try request(path: "v1/account/apple", method: "POST")
        // A stale token from an earlier sign-in must not ride along on a fresh one.
        req.setValue(nil, forHTTPHeaderField: "Authorization")
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
        var req: URLRequest = try request(path: "v1/account", method: "GET")
        req.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        let data: Data = try await send(req)
        do {
            return try JSONDecoder().decode(AccountInfo.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    func signOut(sessionToken: String) async throws {
        var req: URLRequest = try request(path: "v1/account/signout", method: "POST")
        req.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        _ = try await send(req)
    }

    func deleteAccount(sessionToken: String) async throws {
        var req: URLRequest = try request(path: "v1/account", method: "DELETE")
        req.setValue("Bearer " + sessionToken, forHTTPHeaderField: "Authorization")
        _ = try await send(req)
    }
}
