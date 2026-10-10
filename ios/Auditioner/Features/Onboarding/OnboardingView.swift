import SwiftUI

/// CONTRACT (owner: integration agent): instrument + position on first launch.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Button("Start") { settings.hasCompletedOnboarding = true }
    }
}
