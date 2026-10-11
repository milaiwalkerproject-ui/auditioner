import Foundation
import Security

/// What the app keeps about the signed-in account (PLAN B2). Lives only in the keychain of this
/// device, never in UserDefaults or a file. No name and no email: the app doesn't ask Apple for them.
struct StoredAccountSession: Codable, Equatable {
    /// Our server's account id (a UUID string).
    var accountId: String
    /// The bearer token for /v1/account* and the signed-in scan limit. The server keeps only its hash.
    var sessionToken: String
    /// Apple's stable user id for this app, needed to ask Apple whether the sign-in is still valid.
    var appleUserId: String
    /// Scans a day the server allows a signed-in player.
    var dailyScanLimit: Int
}

/// Where the account session is kept. `KeychainStore` is the real one; tests use an in-memory store.
protocol AccountSessionStorage {
    func readSession() -> StoredAccountSession?
    func writeSession(_ session: StoredAccountSession) throws
    func clearSession()
}

/// A small wrapper around the Security framework: one generic-password item per key, readable after
/// the first unlock and never copied to another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
/// Safe to call from any thread.
struct KeychainStore: AccountSessionStorage {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    static let defaultService: String = "com.milaiwalker.auditioner.account"
    static let sessionKey: String = "session"

    /// The store the app uses.
    static let standard: KeychainStore = KeychainStore(service: KeychainStore.defaultService)

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// The session token to send as `Authorization: Bearer …`, or nil when signed out.
    /// Safe from any thread; `APIClient` calls it before every request.
    static func currentSessionToken() -> String? {
        standard.readSession()?.sessionToken
    }

    // MARK: Session

    func readSession() -> StoredAccountSession? {
        guard let data = read(key: KeychainStore.sessionKey) else { return nil }
        return try? JSONDecoder().decode(StoredAccountSession.self, from: data)
    }

    func writeSession(_ session: StoredAccountSession) throws {
        let data: Data = try JSONEncoder().encode(session)
        try write(data, key: KeychainStore.sessionKey)
    }

    func clearSession() {
        delete(key: KeychainStore.sessionKey)
    }

    // MARK: Raw items

    func read(key: String) -> Data? {
        var query: [String: Any] = baseQuery(key: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef? = nil
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data, key: String) throws {
        let query: [String: Any] = baseQuery(key: key)
        let newValue: [String: Any] = [kSecValueData as String: data]
        let updateStatus: OSStatus = SecItemUpdate(query as CFDictionary, newValue as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var item: [String: Any] = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus: OSStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func delete(key: String) {
        let query: [String: Any] = baseQuery(key: key)
        _ = SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
