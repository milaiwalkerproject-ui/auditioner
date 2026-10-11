import SwiftUI
import SwiftData
import UIKit

/// CONTRACT (owner: editor builder): correct the notes the server read from a scan.
/// Presented from the practice player ("Fix notes"), in a sheet or full-screen cover. Calls `onSaved`
/// with the corrected document (origin `.edited`, already saved as a ScoreRecord) so the player can
/// reload it, then dismisses itself.
///
/// Layout: the original scan crop (when the ScoreRecord has one) for comparison, the notation
/// (tap a note to select it; bars that don't add up are tinted red), and the edit palette.
/// iPad (regular width): scan on the left, notation and palette on the right.
struct ScoreEditorView: View {
    let document: ScoreDocument
    var onSaved: (ScoreDocument) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(SettingsKey.tuningA4) private var tuningA4: Double = 440

    @StateObject private var model: ScoreEditorModel
    @StateObject private var preview = EditorPreviewPlayer()

    @State private var scanImage: UIImage?
    @State private var originalScanFileName: String?
    @State private var originalSourceItemId: UUID?
    @State private var loadedOriginal = false
    @State private var notationReady = false
    @State private var notationError: String?
    @State private var showDiscardDialog = false
    @State private var saveError: String?

    init(document: ScoreDocument, onSaved: @escaping (ScoreDocument) -> Void) {
        self.document = document
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: ScoreEditorModel(document: document))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let message = model.loadError {
                    EditorUnavailableView(message: message)
                } else {
                    editorContent
                }
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle(Text("Fix the notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelTapped() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!model.isDirty)
                }
            }
            .confirmationDialog(Text("Discard your changes?"), isPresented: $showDiscardDialog, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) {
                    preview.shutdown()
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("The notes you changed won't be kept.")
            }
            .alert(Text("Couldn't save"), isPresented: saveErrorPresented) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onAppear(perform: loadOriginalRecord)
            .onDisappear {
                preview.shutdown()
            }
        }
        // A sheet with unsaved changes can't be swiped away; Cancel asks first.
        .interactiveDismissDisabled(model.isDirty)
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { shown in if !shown { saveError = nil } })
    }

    // MARK: Layout

    @ViewBuilder
    private var editorContent: some View {
        if horizontalSizeClass == .regular {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    scanPane
                        .frame(width: max(240, proxy.size.width * 0.38))
                    Divider()
                    editingPane
                }
            }
        } else {
            VStack(spacing: 0) {
                if scanImage != nil {
                    scanPane
                        .frame(height: 150)
                    Divider()
                }
                editingPane
            }
        }
    }

    private var scanPane: some View {
        ZStack(alignment: .topLeading) {
            if let image = scanImage {
                ZoomableImageView(image: image)
            } else {
                EditorScanPlaceholder()
            }
            TagPill(text: String(localized: "Your scan"), color: Theme.slate)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipped()
    }

    private var editingPane: some View {
        VStack(spacing: 0) {
            notationArea
            if let hint = model.hint {
                EditorHintBar(text: hint, onDismiss: { model.clearHint() })
            }
            if let message = preview.errorMessage {
                PracticeNoticeBanner(message: message, color: Theme.garnet)
            } else if let message = notationError {
                PracticeNoticeBanner(message: message, color: Theme.garnet)
            }
            EditorPalette(model: model, preview: preview, onPlay: playFromSelection)
        }
    }

    private var notationArea: some View {
        ZStack {
            EditorNotationWebView(
                musicXML: model.musicXML,
                selection: model.selection,
                flaggedMeasures: model.flaggedMeasureIndices,
                highlightBeat: preview.highlightBeat,
                onReady: { notationReady = true },
                onTapNote: { tap in model.select(tap: tap) },
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

    // MARK: Actions

    private func cancelTapped() {
        preview.stop()
        if model.isDirty {
            showDiscardDialog = true
        } else {
            preview.shutdown()
            dismiss()
        }
    }

    private func playFromSelection() {
        if preview.isPlaying {
            preview.stop()
            return
        }
        let measureIndex = model.selection?.measureIndex ?? 0
        preview.play(document: model.correctedDocument, fromMeasure: measureIndex, a4: tuningA4)
    }

    /// Finds the ScoreRecord the document came from (for the scan picture and the My parts link).
    private func loadOriginalRecord() {
        guard !loadedOriginal else { return }
        loadedOriginal = true
        let id = document.id
        let descriptor = FetchDescriptor<ScoreRecord>(predicate: #Predicate<ScoreRecord> { $0.id == id })
        guard let record = (try? modelContext.fetch(descriptor))?.first else { return }
        originalScanFileName = record.scanImageFileName
        originalSourceItemId = record.sourceItemId
        guard let fileName = record.scanImageFileName, !fileName.isEmpty else { return }
        Task {
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                ScanImageStore.loadImage(named: fileName)
            }.value
            scanImage = image
        }
    }

    /// Writes a NEW ScoreRecord (origin `.edited`) and hands it back to the player.
    private func save() {
        preview.stop()
        let record = ScoreRecord(title: EditorLogic.correctedTitle(document.title),
                                 musicXML: model.musicXML,
                                 origin: .edited,
                                 instrument: document.instrument,
                                 excerptId: document.excerptId,
                                 sourceItemId: originalSourceItemId,
                                 warnings: document.warnings)
        record.preferredBPM = document.preferredBPM
        record.scanImageFileName = originalScanFileName
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(record)
            saveError = error.localizedDescription
            return
        }
        preview.shutdown()
        onSaved(record.document)
        dismiss()
    }
}

// MARK: - Small pieces

struct EditorUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkFaint)
            Text("These notes can't be edited")
                .font(Theme.displayFont(.title3))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditorScanPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.viewfinder")
                .font(.title)
                .foregroundStyle(Theme.inkFaint)
            Text("No picture of the scan was kept for this part.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditorHintBar: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.slate)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.inkFaint)
            }
            .accessibilityLabel(Text("Hide this note"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.slate.opacity(0.08))
    }
}
