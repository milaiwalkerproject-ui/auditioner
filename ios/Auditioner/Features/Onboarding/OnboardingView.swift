import SwiftUI

/// First launch: what the app does, what you play, which chair and where.
/// Presented as a sheet by `RootView` until `hasCompletedOnboarding` is true.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings

    @AppStorage(SettingsKey.instrument) private var instrumentRaw: String = Instrument.cello.rawValue
    @AppStorage(SettingsKey.position) private var positionRaw: String = Position.section.rawValue
    @AppStorage(SettingsKey.region) private var region: String = ProfileOptions.defaultRegionId
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false

    @State private var page: Int = 0

    private var instrument: Instrument {
        Instrument(rawValue: instrumentRaw) ?? .cello
    }

    var body: some View {
        TabView(selection: $page) {
            OnboardingWelcomePage(onNext: { goTo(1) })
                .tag(0)
            OnboardingInstrumentPage(instrumentRaw: $instrumentRaw, onNext: { goTo(2) })
                .tag(1)
            OnboardingChairPage(instrument: instrument,
                                positionRaw: $positionRaw,
                                region: $region,
                                onFinish: finish)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Theme.paper.ignoresSafeArea())
        .onChange(of: instrumentRaw) { _, newValue in
            let instrument = Instrument(rawValue: newValue) ?? .cello
            positionRaw = ProfileOptions.validPosition(positionRaw, for: instrument).rawValue
        }
    }

    private func goTo(_ index: Int) {
        withAnimation {
            page = index
        }
    }

    private func finish() {
        if region.isEmpty {
            region = ProfileOptions.defaultRegionId
        }
        hasCompletedOnboarding = true
        settings.hasCompletedOnboarding = true
        // AppSettings keeps its values in @AppStorage, which doesn't publish by itself.
        settings.objectWillChange.send()
    }
}

// MARK: - Page 1: welcome

private struct OnboardingWelcomePage: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Auditioner")
                            .font(Theme.displayFont(.largeTitle))
                            .foregroundStyle(Theme.ink)
                        Text("Prepare for orchestra auditions.")
                            .font(.title3)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        OnboardingBullet(symbol: "doc.viewfinder",
                                         text: String(localized: "Scan or import your part and get reference audio you can slow down and loop."))
                        OnboardingBullet(symbol: "music.note.list",
                                         text: String(localized: "Open the excerpt page: tempo, techniques to watch, history, pitfalls and recordings."))
                        OnboardingBullet(symbol: "pencil.and.outline",
                                         text: String(localized: "Keep your parts in one place, with Apple Pencil markup and page-turn pedals."))
                    }
                    Text("No account needed. Everything works without signing in.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            OnboardingBottomButton(title: String(localized: "Next"), action: onNext)
        }
    }
}

private struct OnboardingBullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Theme.garnet)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Page 2: instrument

private struct OnboardingInstrumentPage: View {
    @Binding var instrumentRaw: String
    let onNext: () -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("What do you play?")
                        .font(Theme.displayFont(.title))
                        .foregroundStyle(Theme.ink)
                    ForEach(Instrument.Family.allCases, id: \.self) { family in
                        familySection(family)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            OnboardingBottomButton(title: String(localized: "Next"), action: onNext)
        }
    }

    private func familySection(_ family: Instrument.Family) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ProfileOptions.familyName(family))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ProfileOptions.instruments(in: family)) { item in
                    OnboardingChoiceChip(title: item.displayName,
                                         isSelected: item.rawValue == instrumentRaw) {
                        instrumentRaw = item.rawValue
                    }
                }
            }
        }
    }
}

// MARK: - Page 3: chair and region

private struct OnboardingChairPage: View {
    let instrument: Instrument
    @Binding var positionRaw: String
    @Binding var region: String
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Which chair?")
                        .font(Theme.displayFont(.title))
                        .foregroundStyle(Theme.ink)
                    Text("Excerpt lists differ by position. You can change this any time in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                    VStack(spacing: 8) {
                        ForEach(ProfileOptions.positions(for: instrument)) { position in
                            OnboardingChoiceRow(title: position.displayName,
                                                isSelected: position.rawValue == positionRaw) {
                                positionRaw = position.rawValue
                            }
                        }
                    }
                    Text("Where do you audition?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.top, 8)
                    Picker(selection: $region) {
                        ForEach(ProfileOptions.regions) { option in
                            Text(option.name).tag(option.id)
                        }
                    } label: {
                        Text("Region")
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.ink)
                    Text("No account needed. Everything works without signing in.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            OnboardingBottomButton(title: String(localized: "Start"), action: onFinish)
        }
    }
}

// MARK: - Shared pieces

private struct OnboardingChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(isSelected ? Color.white : Theme.ink)
                .background(isSelected ? Theme.garnet : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Theme.garnet : Theme.inkFaint.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OnboardingChoiceRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.garnet : Theme.inkFaint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OnboardingBottomButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 40)
    }
}
