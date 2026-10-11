import SwiftUI

/// Drone screen: a sustained note (plus an optional fifth) in the instrument's sound or a pure tone.
struct DroneView: View {
    @StateObject private var engine = DroneEngine()
    @AppStorage(SettingsKey.tuningA4) private var tuningA4: Double = 440
    @AppStorage(SettingsKey.instrument) private var instrumentRaw: String = Instrument.cello.rawValue

    private var instrument: Instrument {
        Instrument(rawValue: instrumentRaw) ?? .cello
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DroneNoteCard(engine: engine, a4: tuningA4)
                DroneOptionsCard(engine: engine, instrumentName: instrument.displayName)
                if let message = engine.errorMessage {
                    PracticeNoticeBanner(message: message, color: Theme.garnet)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                ToolStartStopButton(isRunning: engine.isRunning,
                                    startTitle: String(localized: "Start drone"),
                                    stopTitle: String(localized: "Stop"),
                                    isEnabled: !engine.isStopping && !engine.isLoadingSounds) {
                    engine.toggle()
                }
                Text("The tuning follows the A setting in Settings.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(16)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Drone")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.a4 = tuningA4
            engine.instrument = instrument
            if instrument.family == .percussion || instrument.family == .keyboard {
                engine.sound = .pureTone
            }
        }
        .onChange(of: tuningA4) { _, newValue in
            engine.a4 = newValue
        }
        .onDisappear {
            engine.stop()
        }
    }
}

// MARK: - Note card

struct DroneNoteCard: View {
    @ObservedObject var engine: DroneEngine
    let a4: Double

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var octaveBinding: Binding<Int> {
        Binding(
            get: { engine.note.octave },
            set: { newValue in engine.note = DroneNote(pitchClass: engine.note.pitchClass, octave: newValue) }
        )
    }

    private var frequencyLine: String {
        let parts: [String] = engine.soundingFrequencies.map { DroneMath.frequencyText($0) }
        // The tuning is a label, not a quantity, so it is interpolated as text (never "1,000").
        let tuning: String = String(Int(a4.rounded()))
        return String(localized: "\(parts.joined(separator: " + ")) · A = \(tuning) Hz")
    }

    var body: some View {
        ToolCard(title: String(localized: "Note")) {
            VStack(spacing: 12) {
                Text(engine.note.displayName)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                Text(frequencyLine)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(PitchClass.allCases) { pitchClass in
                        DronePitchButton(pitchClass: pitchClass, isSelected: pitchClass == engine.note.pitchClass) {
                            engine.note = DroneNote(pitchClass: pitchClass, octave: engine.note.octave)
                        }
                    }
                }
                Stepper(value: octaveBinding, in: DroneNote.octaveRange) {
                    Text("Octave: \(engine.note.octave)")
                }
            }
        }
    }
}

struct DronePitchButton: View {
    let pitchClass: PitchClass
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(pitchClass.displayName)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isSelected ? Color.white : Theme.ink)
                .background(isSelected ? Theme.garnet : Theme.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(pitchClass.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Options card

struct DroneOptionsCard: View {
    @ObservedObject var engine: DroneEngine
    let instrumentName: String

    var body: some View {
        ToolCard(title: String(localized: "Sound")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $engine.addFifth) {
                    Text("Add the fifth above")
                }
                Picker(selection: $engine.sound) {
                    ForEach(DroneSound.allCases) { sound in
                        Text(sound == .instrument ? instrumentName : sound.displayName).tag(sound)
                    }
                } label: {
                    Text("Sound")
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(Theme.inkSoft)
                    Slider(value: $engine.volume, in: 0...1)
                        .accessibilityLabel(Text("Volume"))
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(Theme.inkSoft)
                }
                if engine.isLoadingSounds {
                    ProgressView("Loading the sound…")
                        .font(.footnote)
                }
            }
        }
    }
}
