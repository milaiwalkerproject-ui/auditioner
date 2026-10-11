import SwiftUI

/// Metronome screen. When opened from an excerpt, its settings are saved for that excerpt.
struct MetronomeView: View {
    let excerptId: String?

    @StateObject private var engine: MetronomeEngine
    @AppStorage private var presetData: Data

    init(excerptId: String? = nil, startBPM: Double? = nil) {
        self.excerptId = excerptId
        let key = MetronomeMath.presetKey(excerptId: excerptId)
        _presetData = AppStorage(wrappedValue: Data(), key)
        var initial: MetronomeSettings = MetronomeSettings.decoded(from: UserDefaults.standard.data(forKey: key) ?? Data())
            ?? MetronomeSettings()
        if let bpm = startBPM, bpm.isFinite, bpm > 0 {
            initial.bpm = MetronomeMath.clampBPM(bpm.rounded())
        }
        _engine = StateObject(wrappedValue: MetronomeEngine(settings: initial))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MetronomeBeatIndicator(beatsPerBar: engine.settings.beatsPerBar,
                                       currentBeat: engine.currentBeat,
                                       isAccent: engine.currentBeatIsAccent,
                                       beatCounter: engine.beatCounter)
                    .padding(.top, 8)
                MetronomeTempoCard(engine: engine)
                MetronomeOptionsCard(settings: $engine.settings)
                if let message = engine.errorMessage {
                    PracticeNoticeBanner(message: message, color: Theme.garnet)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                ToolStartStopButton(isRunning: engine.isRunning,
                                    startTitle: String(localized: "Start"),
                                    stopTitle: String(localized: "Stop")) {
                    engine.toggle()
                }
                if excerptId != nil {
                    Text("These settings are saved for this excerpt.")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(16)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Metronome")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: engine.settings) { _, newValue in
            presetData = newValue.encoded()
        }
        .onDisappear {
            engine.stop()
        }
    }
}

// MARK: - Beat indicator

struct MetronomeBeatIndicator: View {
    let beatsPerBar: Int
    /// 1-based; 0 while stopped.
    let currentBeat: Int
    let isAccent: Bool
    let beatCounter: Int

    private var dotSize: CGFloat {
        beatsPerBar > 8 ? 18 : 26
    }

    var body: some View {
        HStack(spacing: beatsPerBar > 8 ? 8 : 12) {
            ForEach(1...max(1, beatsPerBar), id: \.self) { beat in
                Circle()
                    .fill(color(for: beat))
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(beat == currentBeat ? 1.25 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: beatCounter)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(currentBeat > 0 ? Text("Beat \(currentBeat) of \(beatsPerBar)") : Text("Stopped"))
    }

    private func color(for beat: Int) -> Color {
        if beat == currentBeat {
            return isAccent ? Theme.garnet : Theme.brass
        }
        return beat == 1 ? Theme.garnet.opacity(0.25) : Theme.inkFaint.opacity(0.3)
    }
}

// MARK: - Tempo card

struct MetronomeTempoCard: View {
    @ObservedObject var engine: MetronomeEngine

    private var bpmBinding: Binding<Double> {
        Binding(get: { engine.settings.bpm }, set: { engine.setBPM($0) })
    }

    var body: some View {
        ToolCard {
            VStack(spacing: 10) {
                Text("\(Int(engine.settings.bpm.rounded()))")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(Text("\(Int(engine.settings.bpm.rounded())) beats per minute"))
                Text("\(engine.settings.beatUnit.symbol) = \(Int(engine.settings.bpm.rounded()))")
                    .font(.title3)
                    .foregroundStyle(Theme.inkSoft)
                HStack(spacing: 4) {
                    Text(MetronomeMath.tempoMarkingHint(bpm: engine.settings.bpm))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.inkSoft)
                    Text("· rough guide only")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkFaint)
                }

                HStack(spacing: 8) {
                    nudgeButton(-5)
                    nudgeButton(-1)
                    Slider(value: bpmBinding, in: MetronomeMath.bpmRange, step: 1)
                        .accessibilityLabel(Text("Tempo"))
                    nudgeButton(1)
                    nudgeButton(5)
                }

                Button {
                    engine.tap()
                } label: {
                    Label("Tap tempo", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text("Tap four times in time to set the tempo"))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func nudgeButton(_ delta: Double) -> some View {
        Button {
            engine.nudgeBPM(by: delta)
        } label: {
            Text(delta > 0 ? "+\(Int(delta))" : "−\(Int(-delta))")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(delta > 0 ? Text("Faster by \(Int(delta))") : Text("Slower by \(Int(-delta))"))
    }
}

// MARK: - Options card

struct MetronomeOptionsCard: View {
    @Binding var settings: MetronomeSettings

    var body: some View {
        ToolCard(title: String(localized: "Beat")) {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: $settings.beatsPerBar, in: MetronomeMath.beatsPerBarRange) {
                    Text("Beats per bar: \(settings.beatsPerBar)")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Beat unit")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                    Picker(selection: $settings.beatUnit) {
                        ForEach(BeatUnit.allCases) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    } label: {
                        Text("Beat unit")
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Subdivide each beat")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                    Picker(selection: $settings.subdivision) {
                        ForEach(Subdivision.allCases) { sub in
                            Text(sub.displayName).tag(sub)
                        }
                    } label: {
                        Text("Subdivision")
                    }
                    .pickerStyle(.segmented)
                }

                Toggle(isOn: $settings.accentFirstBeat) {
                    Text("Accent beat 1")
                }

                HStack {
                    Text("Sound")
                    Spacer()
                    Picker(selection: $settings.sound) {
                        ForEach(ClickSound.allCases) { sound in
                            Text(sound.displayName).tag(sound)
                        }
                    } label: {
                        Text("Sound")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }
}
