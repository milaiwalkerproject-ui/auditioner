import XCTest
import AuthenticationServices
@testable import Auditioner

// MARK: - Fakes

/// Keeps the session in memory so tests never touch the real keychain.
final class MemorySessionStorage: AccountSessionStorage {
    var session: StoredAccountSession? = nil
    var failWrites: Bool = false
    var writeCount: Int = 0
    var clearCount: Int = 0

    struct WriteRefused: Error {}

    func readSession() -> StoredAccountSession? { session }

    func writeSession(_ session: StoredAccountSession) throws {
        if failWrites { throw WriteRefused() }
        writeCount += 1
        self.session = session
    }

    func clearSession() {
        clearCount += 1
        session = nil
    }
}

/// A scripted server: records what it was asked and answers from the fields set by the test.
final class FakeAccountAPI: AccountAPI {
    var signInResponse: AppleSignInResponse = AppleSignInResponse(accountId: "acc-1", sessionToken: "tok-1", dailyScanLimit: 60)
    var signInError: Error? = nil
    var accountInfo: AccountInfo = AccountInfo(accountId: "acc-1", dailyScanLimit: 60, createdAt: "2026-10-11")
    var accountError: Error? = nil
    var signOutError: Error? = nil
    var deleteError: Error? = nil

    var signInCalls: [(identityToken: String, authorizationCode: String, nonce: String)] = []
    var accountTokens: [String] = []
    var signOutTokens: [String] = []
    var deleteTokens: [String] = []

    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String) async throws -> AppleSignInResponse {
        signInCalls.append((identityToken, authorizationCode, nonce))
        if let signInError { throw signInError }
        return signInResponse
    }

    func account(sessionToken: String) async throws -> AccountInfo {
        accountTokens.append(sessionToken)
        if let accountError { throw accountError }
        return accountInfo
    }

    func signOut(sessionToken: String) async throws {
        signOutTokens.append(sessionToken)
        if let signOutError { throw signOutError }
    }

    func deleteAccount(sessionToken: String) async throws {
        deleteTokens.append(sessionToken)
        if let deleteError { throw deleteError }
    }
}

// MARK: - Nonce and hashing

final class AccountNonceTests: XCTestCase {

    func testRandomNonceIsSixtyFourLowercaseHexCharacters() {
        let nonce: String = AccountNonce.random()
        XCTAssertEqual(nonce.count, 64)
        let allowed = Set("0123456789abcdef")
        XCTAssertTrue(nonce.allSatisfy { allowed.contains($0) }, nonce)
        XCTAssertEqual(AccountNonce.random(byteCount: 8).count, 16)
    }

    func testRandomNoncesDiffer() {
        let first: String = AccountNonce.random()
        let second: String = AccountNonce.random()
        XCTAssertNotEqual(first, second)
    }

    func testSHA256HexMatchesKnownVectors() {
        // FIPS 180-4 test vectors.
        XCTAssertEqual(AccountNonce.sha256Hex("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(AccountNonce.sha256Hex(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashedNonceIsWhatTheServerRecomputes() {
        // The server hashes the raw nonce the app sends and compares it with the token's nonce claim.
        let raw: String = AccountNonce.random()
        let hashed: String = AccountNonce.sha256Hex(raw)
        XCTAssertEqual(hashed.count, 64)
        XCTAssertNotEqual(hashed, raw)
        XCTAssertEqual(AccountNonce.sha256Hex(raw), hashed)
    }
}

// MARK: - Server answers

final class AccountDecodingTests: XCTestCase {

    func testDecodesAppleSignInResponse() throws {
        let json = Data(#"{"accountId":"8d1c0e9e-1111-2222-3333-444455556666","sessionToken":"abc_DEF-123","dailyScanLimit":60}"#.utf8)
        let response = try JSONDecoder().decode(AppleSignInResponse.self, from: json)
        XCTAssertEqual(response.accountId, "8d1c0e9e-1111-2222-3333-444455556666")
        XCTAssertEqual(response.sessionToken, "abc_DEF-123")
        XCTAssertEqual(response.dailyScanLimit, 60)
    }

    func testDecodesAccountInfo() throws {
        let json = Data(#"{"accountId":"acc-9","dailyScanLimit":60,"createdAt":"2026-10-11"}"#.utf8)
        let info = try JSONDecoder().decode(AccountInfo.self, from: json)
        XCTAssertEqual(info, AccountInfo(accountId: "acc-9", dailyScanLimit: 60, createdAt: "2026-10-11"))
    }

    func testSignInResponseNeedsAllFields() {
        let json = Data(#"{"accountId":"acc-9"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppleSignInResponse.self, from: json))
    }

    func testStoredSessionRoundTripsThroughJSON() throws {
        let session = StoredAccountSession(accountId: "acc-1", sessionToken: "tok", appleUserId: "001234.abc", dailyScanLimit: 60)
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(StoredAccountSession.self, from: data), session)
    }
}

// MARK: - Plain-words errors

final class AccountErrorWordingTests: XCTestCase {

    func testServerMessageIsShownAsIs() {
        let words = AccountStore.plainWords(for: APIError.server(status: 503, message: "Accounts aren't set up on the server yet."))
        XCTAssertEqual(words, "Accounts aren't set up on the server yet.")
    }

    func testEmptyServerMessageGetsAGenericSentenceWithThePlainStatus() {
        let words = AccountStore.plainWords(for: APIError.server(status: 500, message: ""))
        XCTAssertTrue(words.contains("500"), words)
        XCTAssertFalse(words.contains("scan"), words)
    }

    func testOfflineIsExplained() {
        let words = AccountStore.plainWords(for: URLError(.notConnectedToInternet))
        XCTAssertTrue(words.lowercased().contains("connection"), words)
    }

    func testCancelledAppleSheetIsNotAnError() {
        XCTAssertTrue(AccountStore.isCancellation(ASAuthorizationError(.canceled)))
        XCTAssertFalse(AccountStore.isCancellation(ASAuthorizationError(.failed)))
        XCTAssertFalse(AccountStore.isCancellation(URLError(.timedOut)))
    }
}

// MARK: - State transitions

/// What Apple would answer, scripted. A plain class so the store's nonisolated closure can read it.
final class FakeCredentialProbe {
    var state: ASAuthorizationAppleIDProvider.CredentialState = .authorized
    var checks: [String] = []
}

/// One store with its fakes, built per test (no shared setUp, no real keychain, no real server).
@MainActor
struct AccountHarness {
    let storage: MemorySessionStorage
    let api: FakeAccountAPI
    let probe: FakeCredentialProbe
    let store: AccountStore

    static let session = StoredAccountSession(accountId: "acc-1", sessionToken: "tok-1", appleUserId: "001234.abc", dailyScanLimit: 60)
    static let signedIn: AccountState = .signedIn(accountId: "acc-1", appleUserId: "001234.abc", dailyScanLimit: 60)

    init(session: StoredAccountSession? = nil,
         credential: ASAuthorizationAppleIDProvider.CredentialState = .authorized,
         configure: (FakeAccountAPI, MemorySessionStorage) -> Void = { _, _ in }) {
        let storage = MemorySessionStorage()
        storage.session = session
        let api = FakeAccountAPI()
        let probe = FakeCredentialProbe()
        probe.state = credential
        configure(api, storage)
        self.storage = storage
        self.api = api
        self.probe = probe
        self.store = AccountStore(storage: storage,
                                  makeAPI: { api },
                                  credentialState: { userId in
                                      probe.checks.append(userId)
                                      return probe.state
                                  })
    }
}

@MainActor
final class AccountStoreTests: XCTestCase {

    func testStartsSignedOutWithEmptyStorage() {
        let h = AccountHarness()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertFalse(h.store.state.isSignedIn)
        XCTAssertFalse(h.store.isBusy)
    }

    func testRestoresSessionFromStorage() {
        let h = AccountHarness(session: AccountHarness.session)
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        XCTAssertTrue(h.store.state.isSignedIn)
    }

    func testSignInStoresSessionAndSendsRawNonce() async throws {
        let h = AccountHarness()
        try await h.store.signIn(identityToken: "id-token", authorizationCode: "code", appleUserId: "001234.abc", rawNonce: "raw-nonce")
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        XCTAssertEqual(h.storage.session, AccountHarness.session)
        XCTAssertEqual(h.api.signInCalls.count, 1)
        XCTAssertEqual(h.api.signInCalls.first?.identityToken, "id-token")
        XCTAssertEqual(h.api.signInCalls.first?.authorizationCode, "code")
        XCTAssertEqual(h.api.signInCalls.first?.nonce, "raw-nonce")
        XCTAssertFalse(h.store.isBusy)
    }

    func testSignInFailureLeavesPlayerSignedOut() async {
        let h = AccountHarness { api, _ in
            api.signInError = APIError.server(status: 400, message: "Apple couldn't confirm this sign-in. Try signing in again.")
        }
        do {
            try await h.store.signIn(identityToken: "id", authorizationCode: "code", appleUserId: "u", rawNonce: "n")
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual(AccountStore.plainWords(for: error), "Apple couldn't confirm this sign-in. Try signing in again.")
        }
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertFalse(h.store.isBusy)
    }

    func testSignInClosesServerSessionWhenKeychainRefuses() async {
        let h = AccountHarness { _, storage in storage.failWrites = true }
        do {
            try await h.store.signIn(identityToken: "id", authorizationCode: "code", appleUserId: "u", rawNonce: "n")
            XCTFail("expected a keychain error")
        } catch let error as AccountError {
            XCTAssertEqual(error, .couldNotSaveSession)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertEqual(h.api.signOutTokens, ["tok-1"])
    }

    func testSignOutClearsDeviceAndTellsServer() async {
        let h = AccountHarness(session: AccountHarness.session)
        await h.store.signOut()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertEqual(h.api.signOutTokens, ["tok-1"])
        XCTAssertFalse(h.store.isBusy)
    }

    func testSignOutStillSignsOutLocallyWhenServerIsDown() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.signOutError = URLError(.notConnectedToInternet)
        }
        await h.store.signOut()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
    }

    func testSignOutWhileSignedOutIsHarmless() async {
        let h = AccountHarness()
        await h.store.signOut()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertTrue(h.api.signOutTokens.isEmpty)
    }

    func testDeleteAccountNeedsServerConfirmation() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.deleteError = APIError.server(status: 502, message: "Couldn't reach Apple to finish deleting your account. Try again in a few minutes.")
        }
        do {
            try await h.store.deleteAccount()
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual(AccountStore.plainWords(for: error), "Couldn't reach Apple to finish deleting your account. Try again in a few minutes.")
        }
        // Nothing changed on the device: the account still exists on the server.
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        XCTAssertEqual(h.storage.session, AccountHarness.session)
        XCTAssertEqual(h.api.deleteTokens, ["tok-1"])
        XCTAssertFalse(h.store.isBusy)
    }

    func testDeleteAccountClearsDeviceOnSuccess() async throws {
        let h = AccountHarness(session: AccountHarness.session)
        try await h.store.deleteAccount()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertEqual(h.api.deleteTokens, ["tok-1"])
        XCTAssertTrue(h.api.signOutTokens.isEmpty)
    }

    func testDeleteAccountOnExpiredSessionSignsOutLocally() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.deleteError = APIError.server(status: 401, message: "You're signed out. Sign in again.")
        }
        do {
            try await h.store.deleteAccount()
            XCTFail("expected a signed-out error")
        } catch let error as AccountError {
            XCTAssertEqual(error, .signedOut(message: "You're signed out. Sign in again."))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
    }

    func testRevokedAppleCredentialSignsOut() async {
        let h = AccountHarness(session: AccountHarness.session, credential: .revoked)
        await h.store.refreshCredentialState()
        XCTAssertEqual(h.probe.checks, ["001234.abc"])
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertEqual(h.api.signOutTokens, ["tok-1"])
    }

    func testUnknownAppleCredentialSignsOut() async {
        let h = AccountHarness(session: AccountHarness.session, credential: .notFound)
        await h.store.refreshCredentialState()
        XCTAssertEqual(h.store.state, .signedOut)
    }

    func testAuthorizedAppleCredentialKeepsSession() async {
        let h = AccountHarness(session: AccountHarness.session, credential: .authorized)
        await h.store.refreshCredentialState()
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        XCTAssertEqual(h.storage.session, AccountHarness.session)
        XCTAssertTrue(h.api.signOutTokens.isEmpty)
    }

    func testCredentialCheckIsSkippedWhenSignedOut() async {
        let h = AccountHarness(credential: .revoked)
        await h.store.refreshCredentialState()
        XCTAssertTrue(h.probe.checks.isEmpty)
        XCTAssertEqual(h.store.state, .signedOut)
    }

    func testRefreshFromServerUpdatesScanLimit() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.accountInfo = AccountInfo(accountId: "acc-1", dailyScanLimit: 100, createdAt: "2026-10-11")
        }
        await h.store.refreshFromServer()
        XCTAssertEqual(h.api.accountTokens, ["tok-1"])
        XCTAssertEqual(h.store.state, .signedIn(accountId: "acc-1", appleUserId: "001234.abc", dailyScanLimit: 100))
        XCTAssertEqual(h.storage.session?.dailyScanLimit, 100)
        XCTAssertEqual(h.storage.session?.sessionToken, "tok-1")
    }

    func testRefreshFromServerSignsOutOnExpiredSession() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.accountError = APIError.server(status: 401, message: "You're signed out. Sign in again.")
        }
        await h.store.refreshFromServer()
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
    }

    func testRefreshFromServerKeepsSessionWhenOffline() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.accountError = URLError(.notConnectedToInternet)
        }
        await h.store.refreshFromServer()
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        XCTAssertEqual(h.storage.session, AccountHarness.session)
    }

    func testRefreshFromServerKeepsSessionOnServerTrouble() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.accountError = APIError.server(status: 503, message: "Accounts aren't set up on the server yet.")
        }
        await h.store.refreshFromServer()
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
    }

    func testStateFromSession() {
        XCTAssertEqual(AccountStore.state(from: nil), .signedOut)
        XCTAssertEqual(AccountStore.state(from: AccountHarness.session), AccountHarness.signedIn)
    }
}

// MARK: - Keychain (its own service name, cleaned up afterwards)

final class KeychainStoreTests: XCTestCase {

    private let service: String = "com.milaiwalker.auditioner.tests." + UUID().uuidString
    private var store: KeychainStore { KeychainStore(service: service) }

    override func tearDown() {
        store.clearSession()
        store.delete(key: "raw")
        super.tearDown()
    }

    func testSessionRoundTripAndClear() throws {
        XCTAssertNil(store.readSession())
        let session = StoredAccountSession(accountId: "acc-k", sessionToken: "tok-k", appleUserId: "001234.k", dailyScanLimit: 60)
        try store.writeSession(session)
        XCTAssertEqual(store.readSession(), session)

        var changed: StoredAccountSession = session
        changed.dailyScanLimit = 90
        try store.writeSession(changed)   // second write updates in place
        XCTAssertEqual(store.readSession(), changed)

        store.clearSession()
        XCTAssertNil(store.readSession())
        store.clearSession()              // clearing twice is fine
    }

    func testRawItemsAreKeptPerKey() throws {
        XCTAssertNil(store.read(key: "raw"))
        try store.write(Data("one".utf8), key: "raw")
        XCTAssertEqual(store.read(key: "raw"), Data("one".utf8))
        try store.write(Data("two".utf8), key: "raw")
        XCTAssertEqual(store.read(key: "raw"), Data("two".utf8))
        XCTAssertNil(store.readSession(), "a raw item must not look like a session")
        store.delete(key: "raw")
        XCTAssertNil(store.read(key: "raw"))
    }

    func testServicesAreKeptApart() throws {
        // Different service names never see each other's items; the app's own service is left alone.
        let other = KeychainStore(service: service + ".other")
        try store.write(Data("mine".utf8), key: "raw")
        XCTAssertNil(other.read(key: "raw"))
        XCTAssertNil(other.readSession())
        XCTAssertEqual(KeychainStore.standard.service, "com.milaiwalker.auditioner.account")
    }
}
