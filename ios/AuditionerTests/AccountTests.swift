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

    func testDeleteAccountOnExpiredSessionSignsOutLocallyButSaysTheAccountStillExists() async {
        let h = AccountHarness(session: AccountHarness.session) { api, _ in
            api.deleteError = APIError.server(status: 401, message: "You're signed out. Sign in again.")
        }
        do {
            try await h.store.deleteAccount()
            XCTFail("expected an error: the server did not delete anything")
        } catch let error as AccountError {
            // Not the server's plain "signed out": the player must learn the account is still there.
            XCTAssertEqual(error, .sessionExpiredBeforeDelete)
            XCTAssertEqual(AccountStore.plainWords(for: error),
                           "Your sign-in has expired, so the account wasn't deleted. Sign in again, then delete it.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(h.api.deleteTokens, ["tok-1"])
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertFalse(h.store.isBusy)
    }

    func testDeleteAccountWithUnreadableSessionIsNotReportedAsDeleted() async {
        // The screen says signed in, but the keychain gives nothing back (item gone or unreadable).
        let h = AccountHarness(session: AccountHarness.session)
        XCTAssertEqual(h.store.state, AccountHarness.signedIn)
        h.storage.session = nil
        do {
            try await h.store.deleteAccount()
            XCTFail("expected an error: nothing was sent to the server, so nothing was deleted")
        } catch let error as AccountError {
            XCTAssertEqual(error, .sessionUnreadableBeforeDelete)
            XCTAssertEqual(AccountStore.plainWords(for: error),
                           "We couldn't read your sign-in on this device, so the account wasn't deleted. Sign in again, then delete it.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // The server was never asked, and the device is now honestly signed out so the player can sign in again.
        XCTAssertTrue(h.api.deleteTokens.isEmpty)
        XCTAssertEqual(h.store.state, .signedOut)
        XCTAssertNil(h.storage.session)
        XCTAssertFalse(h.store.isBusy)
    }

    func testDeleteAccountWhileSignedOutIsNotReportedAsDeleted() async {
        let h = AccountHarness()
        do {
            try await h.store.deleteAccount()
            XCTFail("expected an error: there is no session to delete with")
        } catch let error as AccountError {
            XCTAssertEqual(error, .sessionUnreadableBeforeDelete)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(h.api.deleteTokens.isEmpty)
        XCTAssertEqual(h.store.state, .signedOut)
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

// MARK: - Which requests carry the account session (docs/PRIVACY.md)

/// Answers every request from one canned JSON body and remembers the requests, so tests can read the
/// headers the app really sends without a network. Plugged into a `URLSession` per test.
final class RecordingURLProtocol: URLProtocol {
    private static let lock: NSLock = NSLock()
    private static var requests: [URLRequest] = []
    private static var answer: Data = Data("{}".utf8)

    /// Forgets earlier requests and sets the body every request is answered with (200, JSON).
    static func reset(answer json: String) {
        lock.lock()
        defer { lock.unlock() }
        requests = []
        answer = Data(json.utf8)
    }

    static var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func record(_ request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return answer
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data: Data = RecordingURLProtocol.record(request)
        guard let url: URL = request.url, let client: URLProtocolClient = self.client else { return }
        guard let response: HTTPURLResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"]) else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientSessionHeaderTests: XCTestCase {

    /// One body that satisfies every decoder these tests run into (unknown keys are ignored).
    private let everyAnswer: String = """
    {"musicxml":"<score-partwise/>","warnings":[],"engine":"test",
     "auditions":[],"recommendations":[],"candidates":[],
     "enough":false,"fromWeek":"2026-W34","toWeek":"2026-W41","trends":[],
     "accountId":"acc-1","sessionToken":"tok-2","dailyScanLimit":60,"createdAt":"2026-10-11"}
    """

    private var tokenReads: Int = 0

    override func setUp() {
        super.setUp()
        tokenReads = 0
        RecordingURLProtocol.reset(answer: everyAnswer)
    }

    /// A client that talks to `RecordingURLProtocol` and, when `signedIn`, has the session "tok-1".
    private func makeClient(signedIn: Bool) -> APIClient {
        let config: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session: URLSession = URLSession(configuration: config)
        let token: String? = signedIn ? "tok-1" : nil
        return APIClient(baseURL: URL(string: "https://auditioner.test"),
                         deviceId: "device-1",
                         session: session,
                         sessionToken: { [weak self] in
                             self?.tokenReads += 1
                             return token
                         })
    }

    private func authorizationHeaders() -> [String?] {
        RecordingURLProtocol.recorded.map { $0.value(forHTTPHeaderField: "Authorization") }
    }

    private func paths() -> [String] {
        RecordingURLProtocol.recorded.map { $0.url?.path ?? "" }
    }

    // MARK: Request builders

    func testPlainRequestNeverTouchesTheSession() throws {
        let client: APIClient = makeClient(signedIn: true)
        let req: URLRequest = try client.request(path: "v1/feedback", method: "POST")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Id"), "device-1")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "X-App-Version"))
        XCTAssertEqual(tokenReads, 0, "a plain request must not read the keychain")
    }

    func testAuthorizedRequestCarriesTheSessionOnlyWhenSignedIn() throws {
        let signedIn: URLRequest = try makeClient(signedIn: true).request(path: "v1/omr", method: "POST", authorized: true)
        XCTAssertEqual(signedIn.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        let notAsked: URLRequest = try makeClient(signedIn: true).request(path: "v1/omr", method: "POST", authorized: false)
        XCTAssertNil(notAsked.value(forHTTPHeaderField: "Authorization"))
        let signedOut: URLRequest = try makeClient(signedIn: false).request(path: "v1/omr", method: "POST", authorized: true)
        XCTAssertNil(signedOut.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: What each endpoint really sends

    func testOMRUploadCarriesTheSessionWhenSignedIn() async throws {
        let client: APIClient = makeClient(signedIn: true)
        _ = try await client.recognize(imageJPEG: Data([0xFF, 0xD8, 0xFF]), instrument: .cello, transposition: 0, meter: nil, hints: [])
        XCTAssertEqual(paths(), ["/v1/omr"])
        XCTAssertEqual(authorizationHeaders(), ["Bearer tok-1"])
    }

    func testOMRUploadCarriesNoSessionWhenSignedOut() async throws {
        let client: APIClient = makeClient(signedIn: false)
        _ = try await client.recognize(imageJPEG: Data([0xFF, 0xD8, 0xFF]), instrument: .cello, transposition: 0, meter: nil, hints: [])
        XCTAssertEqual(paths(), ["/v1/omr"])
        XCTAssertEqual(authorizationHeaders(), [nil])
    }

    func testFeedbackCarriesNoSessionEvenWhenSignedIn() async throws {
        let client: APIClient = makeClient(signedIn: true)
        try await client.sendFeedback(context: "settings", excerptId: nil, message: "The tempo row is wrong.")
        XCTAssertEqual(paths(), ["/v1/feedback"])
        XCTAssertEqual(authorizationHeaders(), [nil])
        XCTAssertEqual(RecordingURLProtocol.recorded.first?.value(forHTTPHeaderField: "X-Device-Id"), "device-1")
        XCTAssertEqual(tokenReads, 0)
    }

    func testTrendsCarryNoSessionEvenWhenSignedIn() async throws {
        let client: APIClient = makeClient(signedIn: true)
        try await client.shareTrends(instrument: .cello, week: "2026-W41", excerptIds: ["cello-example-1"])
        try await client.forgetTrends()
        _ = try await client.trends(instrument: .cello)
        XCTAssertEqual(paths(), ["/v1/trends", "/v1/trends", "/v1/trends"])
        XCTAssertEqual(authorizationHeaders(), [nil, nil, nil])
        XCTAssertEqual(tokenReads, 0)
    }

    func testFeedRecommendationsAndIdentifyCarryNoSessionEvenWhenSignedIn() async throws {
        let client: APIClient = makeClient(signedIn: true)
        _ = try await client.auditions(instrument: .cello, region: nil)
        _ = try await client.recommendations(instrument: .cello, position: .section, region: nil)
        _ = try await client.identify(ocrText: "Allegro", instrument: .cello)
        XCTAssertEqual(paths(), ["/v1/auditions", "/v1/recommendations", "/v1/identify"])
        XCTAssertEqual(authorizationHeaders(), [nil, nil, nil])
        XCTAssertEqual(tokenReads, 0)
    }

    func testAccountEndpointsCarryTheTokenTheyAreGiven() async throws {
        // The store passes the stored token explicitly; the client's own keychain read is not consulted.
        let client: APIClient = makeClient(signedIn: true)
        _ = try await client.account(sessionToken: "tok-9")
        try await client.signOut(sessionToken: "tok-9")
        try await client.deleteAccount(sessionToken: "tok-9")
        XCTAssertEqual(paths(), ["/v1/account", "/v1/account/signout", "/v1/account"])
        XCTAssertEqual(RecordingURLProtocol.recorded.map { $0.httpMethod }, ["GET", "POST", "DELETE"])
        XCTAssertEqual(authorizationHeaders(), ["Bearer tok-9", "Bearer tok-9", "Bearer tok-9"])
        XCTAssertEqual(tokenReads, 0)
    }

    func testSignInExchangeCarriesNoSession() async throws {
        // A stale token from an earlier sign-in must not ride along on a fresh one.
        let client: APIClient = makeClient(signedIn: true)
        _ = try await client.signInWithApple(identityToken: "id-token", authorizationCode: "code", nonce: "raw-nonce")
        XCTAssertEqual(paths(), ["/v1/account/apple"])
        XCTAssertEqual(authorizationHeaders(), [nil])
        XCTAssertEqual(tokenReads, 0)
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
