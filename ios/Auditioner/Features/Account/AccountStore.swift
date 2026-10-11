import Foundation
import Combine
import AuthenticationServices

/// Whether the player has an (optional) account. Everything in the app works signed out.
enum AccountState: Equatable {
    case signedOut
    case signedIn(accountId: String, appleUserId: String, dailyScanLimit: Int)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// Account problems the app itself notices (server problems arrive as `APIError`).
enum AccountError: LocalizedError, Equatable {
    /// Apple's credential came without an identity token or authorization code.
    case appleSentNothing
    /// The keychain refused to keep the session.
    case couldNotSaveSession
    /// The server no longer knows this session (401); the app has signed out locally.
    case signedOut(message: String)
    /// Delete account: the app says signed in but the keychain gave no session back, so nothing was
    /// sent to the server and nothing was deleted. The app signs out locally.
    case sessionUnreadableBeforeDelete
    /// Delete account: the server answered 401, so the account is still there. The app signs out locally.
    case sessionExpiredBeforeDelete

    var errorDescription: String? {
        switch self {
        case .appleSentNothing:
            return String(localized: "Apple didn't send what the app needs to sign you in. Try again.")
        case .couldNotSaveSession:
            return String(localized: "Couldn't keep your sign-in on this device. Try again.")
        case .signedOut(let message):
            return message.isEmpty ? String(localized: "You're signed out. Sign in again.") : message
        case .sessionUnreadableBeforeDelete:
            return String(localized: "We couldn't read your sign-in on this device, so the account wasn't deleted. Sign in again, then delete it.")
        case .sessionExpiredBeforeDelete:
            return String(localized: "Your sign-in has expired, so the account wasn't deleted. Sign in again, then delete it.")
        }
    }
}

/// Asks Apple whether a sign-in is still valid. Injected so tests don't talk to Apple.
typealias AppleCredentialStateCheck = (_ appleUserId: String) async -> ASAuthorizationAppleIDProvider.CredentialState

/// The one place that knows whether the player is signed in (PLAN B2). Keeps the session in the
/// keychain, talks to the server through `AccountAPI`, and asks Apple at launch whether the sign-in
/// still stands. Signing out clears this device; deleting also removes the account on the server
/// and revokes Apple's token there. Parts, recordings, notes and auditions are never touched.
@MainActor
final class AccountStore: ObservableObject {
    static let shared: AccountStore = AccountStore()

    @Published private(set) var state: AccountState
    @Published private(set) var isBusy: Bool = false

    private let storage: AccountSessionStorage
    private let makeAPI: () -> AccountAPI
    private let credentialState: AppleCredentialStateCheck
    private var revokedObserver: NSObjectProtocol? = nil

    init(storage: AccountSessionStorage = KeychainStore.standard,
         makeAPI: @escaping () -> AccountAPI = { APIClient.fromSettings() },
         credentialState: @escaping AppleCredentialStateCheck = AccountStore.askApple) {
        self.storage = storage
        self.makeAPI = makeAPI
        self.credentialState = credentialState
        self.state = AccountStore.state(from: storage.readSession())
        observeAppleRevocation()
    }

    static func state(from session: StoredAccountSession?) -> AccountState {
        guard let session else { return .signedOut }
        return .signedIn(accountId: session.accountId,
                         appleUserId: session.appleUserId,
                         dailyScanLimit: session.dailyScanLimit)
    }

    // MARK: Sign in

    /// Finishes a Sign in with Apple that the button completed. `rawNonce` is the nonce whose SHA-256
    /// hex went into the request; the server checks it against the token.
    func signIn(with credential: ASAuthorizationAppleIDCredential, rawNonce: String) async throws {
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8), !identityToken.isEmpty,
              let codeData = credential.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8), !authorizationCode.isEmpty else {
            throw AccountError.appleSentNothing
        }
        try await signIn(identityToken: identityToken,
                         authorizationCode: authorizationCode,
                         appleUserId: credential.user,
                         rawNonce: rawNonce)
    }

    /// The testable half of `signIn(with:rawNonce:)`.
    func signIn(identityToken: String, authorizationCode: String, appleUserId: String, rawNonce: String) async throws {
        isBusy = true
        defer { isBusy = false }
        let api: AccountAPI = makeAPI()
        let response: AppleSignInResponse = try await api.signInWithApple(identityToken: identityToken,
                                                                          authorizationCode: authorizationCode,
                                                                          nonce: rawNonce)
        let session = StoredAccountSession(accountId: response.accountId,
                                           sessionToken: response.sessionToken,
                                           appleUserId: appleUserId,
                                           dailyScanLimit: response.dailyScanLimit)
        do {
            try storage.writeSession(session)
        } catch {
            // The server opened a session we can't keep: close it again, best effort.
            try? await api.signOut(sessionToken: response.sessionToken)
            throw AccountError.couldNotSaveSession
        }
        state = AccountStore.state(from: session)
    }

    // MARK: Sign out and delete

    /// Signs out on this device straight away and tells the server, best effort. Never fails: a
    /// server session that couldn't be closed stops working on its own after a year unused.
    func signOut() async {
        guard let session = storage.readSession() else {
            clearLocalSession()
            return
        }
        clearLocalSession()
        isBusy = true
        defer { isBusy = false }
        let api: AccountAPI = makeAPI()
        do {
            try await api.signOut(sessionToken: session.sessionToken)
        } catch {
            NSLog("Auditioner: sign-out wasn't confirmed by the server: %@", String(describing: type(of: error)))
        }
    }

    /// Deletes the account on the server (which revokes Apple's token) and then clears this device.
    /// Returns only when the server confirmed (204): Settings may say "Your account is deleted" on
    /// nothing less. Throws otherwise; nothing changes locally then, except in the two cases where the
    /// session is unusable, which sign the player out here (with an error that says the account is
    /// still there): no session in the keychain (nothing was sent) and a 401 from the server.
    func deleteAccount() async throws {
        guard let session = storage.readSession() else {
            // The screen may say signed in, but there is no session to send. Nothing was deleted;
            // tell the player so, and bring the state in line with the keychain so they can sign in again.
            clearLocalSession()
            throw AccountError.sessionUnreadableBeforeDelete
        }
        isBusy = true
        defer { isBusy = false }
        let api: AccountAPI = makeAPI()
        do {
            try await api.deleteAccount(sessionToken: session.sessionToken)
        } catch let error as APIError {
            if case .server(let status, _) = error, status == 401 {
                // The session is dead but the account is not: say so, don't just say "signed out".
                clearLocalSession()
                throw AccountError.sessionExpiredBeforeDelete
            }
            throw error
        }
        clearLocalSession()
    }

    // MARK: Checks

    /// Asks Apple whether the sign-in still stands (called once at launch). A revoked or unknown
    /// credential signs the player out on this device; the server session is closed best effort.
    func refreshCredentialState() async {
        guard case .signedIn(_, let appleUserId, _) = state else { return }
        let result: ASAuthorizationAppleIDProvider.CredentialState = await credentialState(appleUserId)
        switch result {
        case .revoked, .notFound:
            await signOut()
        case .authorized, .transferred:
            break
        @unknown default:
            break
        }
    }

    /// Asks the server about the account (scan limit may have changed). A 401 signs out locally;
    /// any other problem is ignored, the stored values stay.
    func refreshFromServer() async {
        guard let session = storage.readSession() else { return }
        let api: AccountAPI = makeAPI()
        do {
            let info: AccountInfo = try await api.account(sessionToken: session.sessionToken)
            if info.dailyScanLimit != session.dailyScanLimit || info.accountId != session.accountId {
                var updated: StoredAccountSession = session
                updated.dailyScanLimit = info.dailyScanLimit
                updated.accountId = info.accountId
                try? storage.writeSession(updated)
                state = AccountStore.state(from: updated)
            }
        } catch let error as APIError {
            if case .server(let status, _) = error, status == 401 {
                clearLocalSession()
            }
        } catch {
            // Offline or a server hiccup: keep what we have.
        }
    }

    // MARK: Helpers

    private func clearLocalSession() {
        storage.clearSession()
        state = .signedOut
    }

    private func observeAppleRevocation() {
        revokedObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let store: AccountStore = self else { return }
                await store.refreshCredentialState()
            }
        }
    }

    /// The real check against Apple. `nonisolated` so it can serve as the default for the injected closure.
    nonisolated static func askApple(_ appleUserId: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState, Never>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserId) { credentialState, _ in
                continuation.resume(returning: credentialState)
            }
        }
    }

    /// True when the player closed Apple's sheet without signing in: nothing to report.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if let authError = error as? ASAuthorizationError {
            return authError.code == .canceled
        }
        let nsError = error as NSError
        return nsError.domain == ASAuthorizationErrorDomain && nsError.code == ASAuthorizationError.canceled.rawValue
    }

    /// One plain sentence for the Settings screen.
    nonisolated static func plainWords(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .server(let status, let message):
                if !message.isEmpty { return message }
                return String(localized: "The server couldn't finish this (error \(String(status))). Try again in a few minutes.")
            case .notConfigured, .invalidResponse:
                return apiError.errorDescription ?? String(localized: "Something went wrong. Try again.")
            }
        }
        if let accountError = error as? AccountError {
            return accountError.errorDescription ?? String(localized: "Something went wrong. Try again.")
        }
        if error is URLError {
            return String(localized: "Couldn't reach the server. Check your connection and try again.")
        }
        if error is ASAuthorizationError {
            return String(localized: "Apple couldn't finish the sign-in. Try again.")
        }
        return String(localized: "Something went wrong. Try again.")
    }
}
