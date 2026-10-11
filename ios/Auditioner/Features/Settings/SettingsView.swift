import SwiftUI

/// Settings tab: profile, tuning, server, about. Reviewer mode is hidden behind seven taps on the version row.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @AppStorage(SettingsKey.instrument) private var instrumentRaw: String = Instrument.cello.rawValue
    @AppStorage(SettingsKey.position) private var positionRaw: String = Position.section.rawValue
    @AppStorage(SettingsKey.region) private var region: String = ProfileOptions.defaultRegionId
    @AppStorage(SettingsKey.tuningA4) private var tuningA4: Double = 440
    @AppStorage(SettingsKey.serverURL) private var serverURL: String = ""
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @State private var versionTaps: Int = 0
    @State private var reviewerRevealed: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var connectionResult: ConnectionResult? = nil
    @State private var isSendingFeedback: Bool = false

    private enum ConnectionResult {
        case connected
        case unreachable
        case notSet
        case badAddress
    }

    private var instrument: Instrument {
        Instrument(rawValue: instrumentRaw) ?? .cello
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                tuningSection
                serverSection
                aboutSection
                if reviewerRevealed || reviewerMode {
                    reviewerSection
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .sheet(isPresented: $isSendingFeedback) {
                ReportProblemSheet(context: "settings")
            }
        }
        .onChange(of: instrumentRaw) { _, newValue in
            let instrument = Instrument(rawValue: newValue) ?? .cello
            positionRaw = ProfileOptions.validPosition(positionRaw, for: instrument).rawValue
            settings.objectWillChange.send()
        }
        .onChange(of: positionRaw) { _, _ in settings.objectWillChange.send() }
        .onChange(of: region) { _, _ in settings.objectWillChange.send() }
        .onChange(of: tuningA4) { _, _ in settings.objectWillChange.send() }
        .onChange(of: reviewerMode) { _, _ in settings.objectWillChange.send() }
        .onChange(of: serverURL) { _, _ in
            connectionResult = nil
            settings.objectWillChange.send()
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            Picker(selection: $instrumentRaw) {
                ForEach(Instrument.Family.allCases, id: \.self) { family in
                    Section {
                        ForEach(ProfileOptions.instruments(in: family)) { item in
                            Text(item.displayName).tag(item.rawValue)
                        }
                    } header: {
                        Text(ProfileOptions.familyName(family))
                    }
                }
            } label: {
                Text("Instrument")
            }
            .pickerStyle(.navigationLink)

            Picker(selection: $positionRaw) {
                ForEach(ProfileOptions.positions(for: instrument)) { position in
                    Text(position.displayName).tag(position.rawValue)
                }
            } label: {
                Text("Position")
            }

            Picker(selection: $region) {
                ForEach(ProfileOptions.regions) { option in
                    Text(option.name).tag(option.id)
                }
            } label: {
                Text("Region")
            }
        } header: {
            Text("You")
        } footer: {
            Text("Used to pick which excerpts you see first. Nothing here leaves the device.")
        }
    }

    // MARK: Tuning

    private var tuningSection: some View {
        Section {
            Picker(selection: $tuningA4) {
                ForEach(ProfileOptions.tunings, id: \.self) { value in
                    Text("\(Int(value)) Hz").tag(value)
                }
            } label: {
                Text("Tuning (A4)")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Tuning (A4)")
        } footer: {
            Text("Reference audio is played at this pitch.")
        }
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            TextField("https://…", text: $serverURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                testConnection()
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if isTestingConnection {
                        ProgressView()
                    }
                }
            }
            .disabled(isTestingConnection)
            if let connectionResult {
                connectionResultRow(connectionResult)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Reading notes from a scan needs the Auditioner server. Everything else works without it. Paste the address you were given, starting with https://")
        }
    }

    private func connectionResultRow(_ result: ConnectionResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connectionSymbol(result))
                .foregroundStyle(connectionColor(result))
            Text(connectionText(result))
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private func connectionSymbol(_ result: ConnectionResult) -> String {
        switch result {
        case .connected: return "checkmark.circle.fill"
        case .unreachable, .badAddress: return "xmark.circle.fill"
        case .notSet: return "questionmark.circle"
        }
    }

    private func connectionColor(_ result: ConnectionResult) -> Color {
        switch result {
        case .connected: return Theme.teal
        case .unreachable, .badAddress: return Theme.garnet
        case .notSet: return Theme.inkSoft
        }
    }

    private func connectionText(_ result: ConnectionResult) -> String {
        switch result {
        case .connected: return String(localized: "Connected. Scans will be read by this server.")
        case .unreachable: return String(localized: "Couldn't reach the server. Check the address and your connection.")
        case .notSet: return String(localized: "No address yet. Paste the server address above first.")
        case .badAddress: return String(localized: "The address should start with https://")
        }
    }

    private func testConnection() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            connectionResult = .notSet
            return
        }
        guard settings.serverBaseURL != nil else {
            connectionResult = .badAddress
            return
        }
        isTestingConnection = true
        connectionResult = nil
        let client = APIClient.fromSettings(settings)
        Task {
            let ok: Bool = await client.health()
            isTestingConnection = false
            connectionResult = ok ? .connected : .unreachable
        }
    }

    // MARK: About

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return ScanFlowLogic.versionString(short: short, build: build)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(versionString)
                    .foregroundStyle(Theme.inkSoft)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                registerVersionTap()
            }
            NavigationLink {
                LicencesView()
            } label: {
                Text("Licences")
            }
            NavigationLink {
                PrivacyView()
            } label: {
                Text("Privacy")
            }
            Button {
                isSendingFeedback = true
            } label: {
                Label("Send feedback", systemImage: "bubble.left.and.text.bubble.right")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Questions, ideas or something wrong? Send feedback reaches us directly — there's no public email. Messages go through the Auditioner server; without one they wait on this device.")
        }
    }

    private func registerVersionTap() {
        versionTaps += 1
        if versionTaps >= 7 {
            reviewerRevealed = true
        }
    }

    // MARK: Reviewer mode

    private var reviewerSection: some View {
        Section {
            Toggle(isOn: $reviewerMode) {
                Text("Reviewer mode (show drafts)")
            }
        } header: {
            Text("Catalogue review")
        } footer: {
            Text("For the catalogue reviewer only: shows excerpts that haven't been published yet and notes still waiting for review, marked as drafts. Leave this off unless you're checking the catalogue.")
        }
    }
}
