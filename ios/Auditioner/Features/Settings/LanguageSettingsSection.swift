import SwiftUI
import UIKit

/// Is the app running in a language other than English? UI translations are machine-made and marked
/// "beta" until a native speaker has checked them (PLAN A7). Pure, so it can be unit-tested.
enum LocalizationStatus {
    /// `preferredLocalizations` as `Bundle.main.preferredLocalizations` gives it, best match first.
    static func isBetaTranslation(preferredLocalizations: [String]) -> Bool {
        guard let first = preferredLocalizations.first else { return false }
        let code: String = first.lowercased()
        return !(code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_"))
    }

    static var isRunningInBetaTranslation: Bool {
        isBetaTranslation(preferredLocalizations: Bundle.main.preferredLocalizations)
    }
}

/// Settings → Language (PLAN A7). iOS lets the player pick a language per app in the system Settings;
/// "App language" takes them straight to Auditioner's page there.
struct LanguageSettingsSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Button {
                openAppSettings()
            } label: {
                HStack(spacing: 8) {
                    Label("App language", systemImage: "globe")
                    Spacer()
                    if LocalizationStatus.isRunningInBetaTranslation {
                        TagPill(text: String(localized: "Beta translation"), color: Theme.brass)
                    }
                    Image(systemName: "arrow.up.forward.app")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("The app follows your device language when a translation exists. Translations are machine-made and marked beta until a native speaker has checked them. Work titles and score markings stay in the original language. Spot a mistake? Use Send feedback.")
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
