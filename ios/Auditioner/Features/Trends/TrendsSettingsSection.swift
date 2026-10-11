import SwiftUI

/// Settings → "Popular with other players" (PLAN D6): the opt-in switch (off by default), the
/// 18-or-older question before it goes on, and plain words on what is sent and who sees the lists.
struct TrendsSettingsSection: View {
    @AppStorage(TrendsSettings.sharingKey) private var sharing: Bool = false
    @AppStorage(TrendsSettings.adultConfirmedKey) private var adultConfirmed: Bool = false

    @State private var askAge: Bool = false
    @State private var showsAgeNote: Bool = false

    var body: some View {
        Section {
            Toggle(isOn: sharingBinding) {
                Text(TrendsCopy.shareToggle)
            }
            .confirmationDialog(Text(TrendsCopy.ageQuestion), isPresented: $askAge, titleVisibility: .visible) {
                Button(TrendsCopy.ageYes) {
                    confirmAdult()
                }
                Button(TrendsCopy.ageNo, role: .cancel) {
                    showsAgeNote = true
                }
            } message: {
                Text(TrendsCopy.ageNote)
            }
            if showsAgeNote {
                Text(TrendsCopy.ageNote)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        } header: {
            Text(TrendsCopy.settingsHeader)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(TrendsCopy.whatIsSent)
                Text(TrendsCopy.whoSees)
            }
        }
    }

    /// Turning on goes through the age question; turning off takes effect at once.
    private var sharingBinding: Binding<Bool> {
        Binding(
            get: { sharing },
            set: { wantsOn in
                if wantsOn {
                    requestOn()
                } else {
                    turnOff()
                }
            }
        )
    }

    private func requestOn() {
        showsAgeNote = false
        if adultConfirmed {
            sharing = true
        } else {
            askAge = true
        }
    }

    private func confirmAdult() {
        adultConfirmed = true
        sharing = true
        showsAgeNote = false
    }

    private func turnOff() {
        guard sharing else { return }
        sharing = false
        Task {
            await TrendsUploader.shared.sharingTurnedOff()
        }
    }
}
