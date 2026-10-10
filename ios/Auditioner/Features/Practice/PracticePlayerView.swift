import SwiftUI
import UIKit

/// Notation + reference playback for a score: tempo, loop, count-in, tuning, "play from here", save audio.
struct PracticePlayerView: View {
    let document: ScoreDocument

    @EnvironmentObject private var router: AppRouter
    @StateObject private var engine: PlaybackEngine
    @AppStorage(SettingsKey.tuningA4) private var tuningA4: Double = 440

    @State private var notationReady = false
    @State private var notationError: String?
    @State private var exportedFile: ExportedAudioFile?
    @State private var exportError: String?

    init(document: ScoreDocument) {
        self.document = document
        _engine = StateObject(wrappedValue: PlaybackEngine(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            PracticeTopBar(title: document.title, origin: document.origin, onClose: close)
            if !document.warnings.isEmpty {
                PracticeWarningsBanner(warnings: document.warnings)
            }
            if let message = engine.errorMessage {
                PracticeNoticeBanner(message: message, color: Theme.garnet)
            } else if let message = notationError {
                PracticeNoticeBanner(message: message, color: Theme.garnet)
            }
            notationArea
            PracticeTransportBar(engine: engine, tuningA4: $tuningA4, onSaveAudio: saveAudio)
        }
        .background(Theme.paper.ignoresSafeArea())
        .onAppear {
            engine.prepare()
            engine.a4 = tuningA4
        }
        .onDisappear {
            engine.shutdown()
        }
        .onChange(of: tuningA4) { _, newValue in
            engine.a4 = newValue
        }
        .sheet(item: $exportedFile) { file in
            PracticeExportSheet(file: file)
        }
        .alert(Text("Couldn't save the audio"), isPresented: exportErrorPresented) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { shown in if !shown { exportError = nil } })
    }

    private var notationArea: some View {
        ZStack {
            NotationWebView(
                musicXML: document.musicXML,
                highlightBeat: engine.isReady ? engine.currentBeat : nil,
                onReady: { _, _ in notationReady = true },
                onTapNote: { qstamp in engine.play(fromBeat: qstamp) },
                onError: { message in notationError = message }
            )
            if !notationReady && notationError == nil {
                ProgressView("Drawing the music…")
                    .padding()
                    .background(Theme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() {
        engine.shutdown()
        router.practiceDocument = nil
    }

    private func saveAudio() {
        let fileName = PracticePlayerView.audioFileName(for: document.title)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        Task {
            do {
                try await engine.exportAudio(to: url)
                exportedFile = ExportedAudioFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// "Strauss · Don Juan" → "Strauss-Don-Juan.m4a"
    static func audioFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var cleaned = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !cleaned.isEmpty {
                cleaned += "-"
                lastWasDash = true
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        if cleaned.isEmpty { cleaned = "Auditioner-reference" }
        return cleaned + ".m4a"
    }
}

struct ExportedAudioFile: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Top bar

struct PracticeTopBar: View {
    let title: String
    let origin: ScoreOrigin
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Text("Close")
            }
            .accessibilityLabel(Text("Close the player"))
            Spacer(minLength: 8)
            VStack(spacing: 4) {
                Text(title)
                    .font(Theme.displayFont(.headline))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                TagPill(text: PracticeTopBar.originText(origin), color: PracticeTopBar.originColor(origin))
            }
            Spacer(minLength: 8)
            // Keeps the title centred.
            Text("Close").opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    static func originText(_ origin: ScoreOrigin) -> String {
        switch origin {
        case .demo: return String(localized: "Demo")
        case .omr: return String(localized: "Read from your scan — check the notes")
        case .edited: return String(localized: "Your corrected version")
        case .curated: return String(localized: "Checked transcription")
        }
    }

    static func originColor(_ origin: ScoreOrigin) -> Color {
        switch origin {
        case .demo: return Theme.slate
        case .omr: return Theme.garnet
        case .edited: return Theme.teal
        case .curated: return Theme.brass
        }
    }
}

// MARK: - Banners

struct PracticeWarningsBanner: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Things to check against your part")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Theme.garnet)
            ForEach(Array(warnings.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.garnet.opacity(0.08))
    }
}

struct PracticeNoticeBanner: View {
    let message: String
    var color: Color = Theme.slate

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.08))
    }
}

// MARK: - Transport

struct PracticeTransportBar: View {
    @ObservedObject var engine: PlaybackEngine
    @Binding var tuningA4: Double
    let onSaveAudio: () -> Void

    static let tunings: [Double] = [440, 441, 442, 443]
    static let tempoRange: ClosedRange<Double> = 40...200

    var body: some View {
        VStack(spacing: 10) {
            transportRow
            tempoRow
            optionsRow
            if engine.loopEnabled {
                loopRow
            }
            actionsRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.surface)
    }

    private var tempoLabel: String {
        "♩ = \(Int(engine.tempoBPM.rounded()))"
    }

    private var maxMeasureIndex: Int {
        max(0, engine.measureCount - 1)
    }

    private var transportRow: some View {
        HStack(spacing: 20) {
            Button {
                engine.stop()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
            }
            .accessibilityLabel(Text("Back to start"))

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .frame(width: 56, height: 44)
            }
            .accessibilityLabel(engine.isPlaying ? Text("Pause") : Text("Play"))

            Spacer()

            if engine.isCountingIn {
                Text("Count-in…")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }

            Text(tempoLabel)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityLabel(Text("Tempo \(Int(engine.tempoBPM.rounded())) beats per minute"))

            Button {
                engine.nudgeTempo(by: -5)
            } label: {
                Text("−5")
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Slow down by 5"))

            Button {
                engine.nudgeTempo(by: 5)
            } label: {
                Text("+5")
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Speed up by 5"))
        }
        .disabled(!engine.isReady)
    }

    private var tempoRow: some View {
        Slider(value: $engine.tempoBPM, in: PracticeTransportBar.tempoRange, step: 1)
            .accessibilityLabel(Text("Tempo"))
            .disabled(!engine.isReady)
    }

    private var optionsRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $engine.countInEnabled) {
                Label("Count-in", systemImage: "metronome")
            }
            .toggleStyle(.button)

            Toggle(isOn: $engine.loopEnabled) {
                Label("Loop", systemImage: "repeat")
            }
            .toggleStyle(.button)

            Spacer()

            Picker(selection: $tuningA4) {
                ForEach(PracticeTransportBar.tunings, id: \.self) { value in
                    Text("A = \(Int(value)) Hz").tag(value)
                }
            } label: {
                Text("Tuning")
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text("Tuning of A"))
        }
        .disabled(!engine.isReady)
    }

    private var loopRow: some View {
        HStack(spacing: 16) {
            Stepper(value: $engine.loopStartMeasure, in: 0...maxMeasureIndex) {
                Text("From bar \(engine.measureLabel(forIndex: engine.loopStartMeasure))")
                    .font(.subheadline)
            }
            Stepper(value: $engine.loopEndMeasure, in: 0...maxMeasureIndex) {
                Text("To bar \(engine.measureLabel(forIndex: engine.loopEndMeasure))")
                    .font(.subheadline)
            }
        }
        .disabled(!engine.isReady)
    }

    private var actionsRow: some View {
        HStack {
            Spacer()
            Button {
                onSaveAudio()
            } label: {
                if engine.isExporting {
                    Label {
                        Text("Saving…")
                    } icon: {
                        ProgressView()
                    }
                } else {
                    Label("Save audio", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!engine.isReady || engine.isExporting)
            Spacer()
        }
    }
}

// MARK: - Export sheet

struct PracticeExportSheet: View {
    let file: ExportedAudioFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.brass)
                Text(file.url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("The reference audio at your tempo and tuning, without the count-in. Share it, or save it to Files.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
                ShareLink(item: file.url) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
