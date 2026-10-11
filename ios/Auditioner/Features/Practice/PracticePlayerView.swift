import SwiftUI
import SwiftData
import UIKit

/// Notation + reference playback for a score: tempo, loop, count-in, tuning, "play from here", save audio,
/// record & compare, and "Fix notes" for scanned parts.
///
/// The document can be replaced by the correction editor; the content view is keyed on it so the
/// notation and the playback engine reload from scratch.
struct PracticePlayerView: View {
    @State private var document: ScoreDocument

    init(document: ScoreDocument) {
        _document = State(initialValue: document)
    }

    var body: some View {
        PracticePlayerContent(document: document, onReplaceDocument: { newDocument in
            document = newDocument
        })
        .id(document)
    }

    /// Kept for callers that used the old name; the logic lives in `PracticeExport` (plain, testable).
    static func audioFileName(for title: String) -> String {
        PracticeExport.audioFileName(for: title)
    }
}

struct PracticePlayerContent: View {
    let document: ScoreDocument
    let onReplaceDocument: (ScoreDocument) -> Void

    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @StateObject private var engine: PlaybackEngine
    @StateObject private var compare = RecordCompareSession()
    @AppStorage(SettingsKey.tuningA4) private var tuningA4: Double = 440

    @State private var notationReady = false
    @State private var notationError: String?
    @State private var exportedFile: ExportedAudioFile?
    @State private var exportError: String?
    @State private var compareItem: CompareSheetItem?
    @State private var lastCompareItem: CompareSheetItem?
    @State private var showEditor: Bool = false
    @State private var micDenied: Bool = false
    @State private var referenceTempURL: URL?

    init(document: ScoreDocument, onReplaceDocument: @escaping (ScoreDocument) -> Void) {
        self.document = document
        self.onReplaceDocument = onReplaceDocument
        _engine = StateObject(wrappedValue: PlaybackEngine(document: document))
    }

    private var canFixNotes: Bool {
        document.origin == .omr || document.origin == .edited
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
            PracticeTransportBar(engine: engine, tuningA4: $tuningA4, onSaveAudio: saveAudio,
                                 onFixNotes: canFixNotes ? { showEditor = true } : nil)
            RecordCompareBar(session: compare, engine: engine, hasLastTake: lastCompareItem != nil,
                             onRecord: startRecording, onStop: stopRecording,
                             onCompare: { compareItem = lastCompareItem })
        }
        .background(Theme.paper.ignoresSafeArea())
        .onAppear {
            engine.prepare()
            engine.a4 = tuningA4
            compare.onAutoStop = { stopRecording() }
            compare.onInterrupted = { stopRecording() }
        }
        .onDisappear {
            compare.onAutoStop = nil
            compare.onInterrupted = nil
            _ = compare.stop()
            engine.shutdown()
            removeReferenceTemp()
        }
        .onChange(of: tuningA4) { _, newValue in
            engine.a4 = newValue
        }
        .sheet(item: $exportedFile) { file in
            PracticeExportSheet(file: file)
        }
        .sheet(item: $compareItem) { item in
            CompareSheet(item: item)
        }
        .sheet(isPresented: $showEditor) {
            ScoreEditorView(document: document, onSaved: { newDocument in
                showEditor = false
                onReplaceDocument(newDocument)
            })
        }
        .alert(Text("Couldn't save the audio"), isPresented: exportErrorPresented) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert(Text("Microphone is off"), isPresented: $micDenied) {
            Button("Open Settings") {
                if let url = AudioSessionCoordinator.settingsURL {
                    openURL(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Recording needs the microphone. Turn it on for Auditioner in Settings, then try again.")
        }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { shown in if !shown { exportError = nil } })
    }

    /// The reference's beat while recording against it, otherwise the player's.
    private var highlightBeat: Double? {
        if compare.isActive {
            return compare.referenceBeat
        }
        return engine.isReady ? engine.currentBeat : nil
    }

    private var notationArea: some View {
        ZStack {
            NotationWebView(
                musicXML: document.musicXML,
                highlightBeat: highlightBeat,
                onReady: { _, _ in notationReady = true },
                onTapNote: { qstamp in
                    if !compare.isBusy {
                        engine.play(fromBeat: qstamp)
                    }
                },
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
        _ = compare.stop()
        engine.shutdown()
        router.practiceDocument = nil
    }

    private func saveAudio() {
        let fileName = PracticeExport.audioFileName(for: document.title)
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

    // MARK: Record & compare

    /// Record: pause the player, get the microphone, render the reference at the current tempo, then start
    /// the session (a one-bar count-in when the player's Count-in switch is on — Milai's decision, 2026-10-11 —
    /// then the reference from the current position, microphone recorded alongside).
    private func startRecording() {
        guard engine.isReady, let timeline = engine.timeline, !compare.isBusy else { return }
        engine.pause()
        compare.clearError()
        AudioSessionCoordinator.shared.requestMicPermission { granted in
            if granted {
                prepareAndRecord(timeline: timeline)
            } else {
                micDenied = true
            }
        }
    }

    private func prepareAndRecord(timeline: PlaybackTimeline) {
        let startBeat: Double = engine.loopEnabled
            ? timeline.startBeat(ofMeasure: engine.loopStartMeasure)
            : engine.currentBeat
        let tempo: Double = engine.tempoBPM
        let countIn = timeline.countIn(bars: 1)
        let useCountIn: Bool = engine.countInEnabled
        let clickSeconds: Double = countIn.clickSpacingBeats * 60.0 / max(1, tempo)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compare-reference-\(UUID().uuidString).m4a")
        removeReferenceTemp()
        referenceTempURL = url
        let fileName = TakeStore.newFileName(title: document.title)
        let title = document.title
        compare.markPreparing()

        Task { @MainActor in
            do {
                try await engine.exportAudio(to: url)
                let duration: Double = TakeStore.durationSeconds(of: url)
                    ?? timeline.seconds(atBeat: timeline.totalBeats, targetBPM: tempo)
                let plan = RecordComparePlan(referenceURL: url,
                                             referenceOffsetSeconds: timeline.seconds(atBeat: startBeat, targetBPM: tempo),
                                             referenceDurationSeconds: duration,
                                             countInClicks: useCountIn ? countIn.clickCount : 0,
                                             clicksPerBar: countIn.clicksPerBar,
                                             countInClickSeconds: clickSeconds,
                                             tempoBPM: tempo,
                                             startBeat: startBeat,
                                             timeline: timeline,
                                             takeFileName: fileName,
                                             title: title)
                compare.start(plan)
            } catch {
                compare.fail(error.localizedDescription)
            }
        }
    }

    /// Stop: save the take and open the compare sheet.
    private func stopRecording() {
        guard let result = compare.stop() else { return }
        let take = PracticeTake(title: result.plan.title, fileName: result.fileName, durationSeconds: result.durationSeconds)
        take.excerptId = document.excerptId
        TrendsTracker.shared.notePractised(excerptId: document.excerptId, instrument: document.instrument) // D6, only while sharing is on
        take.scoreId = (document.origin == .demo) ? nil : document.id
        take.referenceBPM = result.plan.tempoBPM
        take.referenceStartBeat = result.plan.startBeat
        modelContext.insert(take)
        try? modelContext.save()
        let item = CompareSheetItem(take: take,
                                    referenceURL: result.plan.referenceURL,
                                    referenceOffsetSeconds: result.plan.referenceOffsetSeconds)
        lastCompareItem = item
        compareItem = item
    }

    private func removeReferenceTemp() {
        if let url = referenceTempURL {
            try? FileManager.default.removeItem(at: url)
            referenceTempURL = nil
        }
    }
}

/// Pure helpers for the "Save audio" feature (no SwiftUI, so tests can call them directly).
enum PracticeExport {
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
    /// Shown as a "Fix notes" button when set (scanned or corrected parts).
    var onFixNotes: (() -> Void)? = nil

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
        HStack(spacing: 12) {
            Spacer()
            if let onFixNotes = onFixNotes {
                Button {
                    onFixNotes()
                } label: {
                    Label("Fix notes", systemImage: "pencil.and.outline")
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text("Correct the notes read from your scan"))
            }
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
