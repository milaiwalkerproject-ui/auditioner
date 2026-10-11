import SwiftUI

/// The edit buttons under the notation: pitch, accidentals, lengths, rest/tie/insert/delete,
/// undo/redo, "Play from here" and the list of bars that don't add up.
struct EditorPalette: View {
    @ObservedObject var model: ScoreEditorModel
    @ObservedObject var preview: EditorPreviewPlayer
    let onPlay: () -> Void

    private var hasSelection: Bool { model.canEdit && model.selection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorSelectionLine(model: model)
            paletteRow { pitchButtons }
            paletteRow { lengthButtons }
            paletteRow { structureButtons }
            bottomRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.surface)
    }

    private func paletteRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var pitchButtons: some View {
        EditorToolButton(title: String(localized: "Up"), systemImage: "arrow.up", disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.pitchUp)
        }
        EditorToolButton(title: String(localized: "Down"), systemImage: "arrow.down", disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.pitchDown)
        }
        EditorToolButton(title: "♯", accessibilityTitle: String(localized: "Sharp"), disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.accidental(.sharp))
        }
        EditorToolButton(title: "♭", accessibilityTitle: String(localized: "Flat"), disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.accidental(.flat))
        }
        EditorToolButton(title: "♮", accessibilityTitle: String(localized: "Natural"), disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.accidental(.natural))
        }
        EditorToolButton(title: String(localized: "No sign"), accessibilityTitle: String(localized: "Remove the accidental"), disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.accidental(.none))
        }
    }

    @ViewBuilder
    private var lengthButtons: some View {
        ForEach(NoteValue.allCases) { value in
            EditorToolButton(title: value.label, disabled: !hasSelection) {
                model.apply(.duration(value))
            }
        }
        EditorToolButton(title: String(localized: "Dot"), isOn: model.selectedHasDot, disabled: !hasSelection) {
            model.apply(.toggleDot)
        }
    }

    @ViewBuilder
    private var structureButtons: some View {
        EditorToolButton(title: String(localized: "Rest"), isOn: model.selectedIsRest, disabled: !hasSelection) {
            model.apply(.toggleRest)
        }
        EditorToolButton(title: String(localized: "Tie"), isOn: model.selectedIsTied, disabled: !hasSelection || model.selectedIsRest) {
            model.apply(.toggleTie)
        }
        EditorToolButton(title: String(localized: "Insert"), systemImage: "plus", disabled: !hasSelection) {
            model.apply(.insertAfter)
        }
        EditorToolButton(title: String(localized: "Delete"), systemImage: "trash", disabled: !hasSelection) {
            model.apply(.delete)
        }
        EditorToolButton(title: String(localized: "Undo"), systemImage: "arrow.uturn.backward", disabled: !model.canUndo) {
            model.undo()
        }
        EditorToolButton(title: String(localized: "Redo"), systemImage: "arrow.uturn.forward", disabled: !model.canRedo) {
            model.redo()
        }
    }

    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onPlay) {
                if preview.isPreparing {
                    Label {
                        Text("Loading…")
                    } icon: {
                        ProgressView()
                    }
                } else if preview.isPlaying {
                    Label("Stop", systemImage: "stop.fill")
                } else {
                    Label("Play from here", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canEdit || preview.isPreparing)
            .accessibilityLabel(preview.isPlaying ? Text("Stop the preview") : Text("Play from the selected bar"))

            EditorBarsToCheck(model: model)
        }
    }
}

/// "Bar 3, note 2" or an invitation to tap a note.
struct EditorSelectionLine: View {
    @ObservedObject var model: ScoreEditorModel

    var body: some View {
        HStack(spacing: 6) {
            if let selection = model.selection {
                let number = model.measureNumbers.indices.contains(selection.measureIndex)
                    ? model.measureNumbers[selection.measureIndex]
                    : String(selection.measureIndex + 1)
                Image(systemName: "hand.tap")
                    .foregroundStyle(Theme.teal)
                Text("Bar \(number), note \(selection.noteIndex + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            } else {
                Image(systemName: "hand.tap")
                    .foregroundStyle(Theme.inkFaint)
                Text("Tap a note to edit it")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
        }
    }
}

/// Chips for the bars whose notes don't add up; tapping one selects the bar's first note.
struct EditorBarsToCheck: View {
    @ObservedObject var model: ScoreEditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.issues.isEmpty {
                    Label("All bars add up", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.teal)
                } else {
                    Label("Bars to check", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.garnet)
                    ForEach(model.issues, id: \.measureIndex) { issue in
                        Button {
                            model.selectFirstNote(inMeasure: issue.measureIndex)
                        } label: {
                            Text(EditorLogic.issueText(issue))
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.garnet)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// One palette button. `isOn` shows the state of a toggle (dot, rest, tie).
struct EditorToolButton: View {
    let title: String
    var systemImage: String? = nil
    var accessibilityTitle: String? = nil
    var isOn: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    init(title: String, systemImage: String? = nil, accessibilityTitle: String? = nil, isOn: Bool = false,
         disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityTitle = accessibilityTitle
        self.isOn = isOn
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage = systemImage {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
            } else {
                Text(title)
                    .font(.subheadline)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isOn ? Theme.teal : Theme.slate)
        .disabled(disabled)
        .accessibilityLabel(Text(accessibilityTitle ?? title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
