import SwiftUI
import AuthenticationServices

/// Settings → Account (PLAN B2). Optional Sign in with Apple, sign out, and in-app account deletion.
/// Dropped into `SettingsView`'s Form right after the profile section.
struct AccountSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store: AccountStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var rawNonce: String = ""
    @State private var errorMessage: String? = nil
    @State private var showsDeletedNote: Bool = false
    @State private var isConfirmingDelete: Bool = false

    init(store: AccountStore = AccountStore.shared) {
        self._store = ObservedObject(wrappedValue: store)
    }

    private var serverIsSet: Bool {
        settings.serverBaseURL != nil
    }

    var body: some View {
        Section {
            switch store.state {
            case .signedOut:
                signedOutRows
            case .signedIn(_, _, let dailyScanLimit):
                signedInRows(dailyScanLimit: dailyScanLimit)
            }
            if let errorMessage {
                noteRow(errorMessage, symbol: "exclamationmark.circle.fill", color: Theme.garnet)
            }
        } header: {
            Text("Account")
                // Modifiers go on a row or the header, not on the Section itself, so the Form still
                // lays it out as a section.
                .task(id: store.state.isSignedIn) {
                    if store.state.isSignedIn {
                        await store.refreshFromServer()
                    }
                }
        } footer: {
            footerText
        }
    }

    // MARK: Signed out

    @ViewBuilder
    private var signedOutRows: some View {
        if showsDeletedNote {
            noteRow(String(localized: "Your account is deleted."), symbol: "checkmark.circle.fill", color: Theme.teal)
        }
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = []
            let nonce: String = AccountNonce.random()
            rawNonce = nonce
            request.nonce = AccountNonce.sha256Hex(nonce)
        } onCompletion: { result in
            handleAppleResult(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .disabled(!serverIsSet || store.isBusy)
        .opacity(serverIsSet ? 1 : 0.5)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityHint(serverIsSet ? Text("Optional. Gives you more scans a day.") : Text("Accounts need the server, which isn't set up yet."))
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedInRows(dailyScanLimit: Int) -> some View {
        Label("Signed in with Apple", systemImage: "apple.logo")
        HStack {
            Text("Scans a day")
            Spacer()
            Text(String(dailyScanLimit))
                .foregroundStyle(Theme.inkSoft)
        }
        Button {
            signOut()
        } label: {
            HStack {
                Text("Sign out")
                Spacer()
                if store.isBusy {
                    ProgressView()
                }
            }
        }
        .disabled(store.isBusy)
        Button(role: .destructive) {
            errorMessage = nil
            isConfirmingDelete = true
        } label: {
            Text("Delete account")
        }
        .disabled(store.isBusy)
        .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your account on our server and disconnects Apple. Your parts, recordings, notes and auditions stay on this device.")
        }
    }

    // MARK: Footer and notes

    private var footerText: Text {
        switch store.state {
        case .signedOut:
            if serverIsSet {
                return Text("Optional. Signing in gives you more scans a day. Everything else works without an account. We don't ask Apple for your name or email.")
            }
            return Text("Optional. Signing in gives you more scans a day. Everything else works without an account. Accounts need the server, which isn't set up yet.")
        case .signedIn:
            return Text("Signing out keeps everything on this device. Deleting removes your account from our server and disconnects Apple; your parts, recordings, notes and auditions stay here.")
        }
    }

    private func noteRow(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    // MARK: Actions

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = AccountStore.plainWords(for: AccountError.appleSentNothing)
                return
            }
            let nonce: String = rawNonce
            errorMessage = nil
            showsDeletedNote = false
            Task {
                do {
                    try await store.signIn(with: credential, rawNonce: nonce)
                } catch {
                    errorMessage = AccountStore.plainWords(for: error)
                }
            }
        case .failure(let error):
            if AccountStore.isCancellation(error) { return }
            errorMessage = AccountStore.plainWords(for: error)
        }
    }

    private func signOut() {
        errorMessage = nil
        Task {
            await store.signOut()
        }
    }

    private func deleteAccount() {
        errorMessage = nil
        Task {
            do {
                try await store.deleteAccount()
                showsDeletedNote = true
            } catch {
                errorMessage = AccountStore.plainWords(for: error)
            }
        }
    }
}
