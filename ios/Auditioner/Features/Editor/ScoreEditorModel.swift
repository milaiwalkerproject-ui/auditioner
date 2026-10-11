import Foundation
import Combine

/// One palette action.
enum ScoreEdit: Equatable {
    case pitchUp
    case pitchDown
    case accidental(AccidentalChoice)
    case duration(NoteValue)
    case toggleDot
    case toggleRest
    case toggleTie
    case insertAfter
    case delete
}

/// State of the correction editor: the MusicXML being edited, the selected note, the bar check and undo/redo.
@MainActor
final class ScoreEditorModel: ObservableObject {
    let document: ScoreDocument

    @Published private(set) var musicXML: String
    @Published private(set) var selection: NoteAddress?
    @Published private(set) var issues: [BarCheckIssue] = []
    @Published private(set) var measureNumbers: [String] = []
    /// Why the last action did nothing, in plain words (shown briefly under the music).
    @Published private(set) var hint: String?
    /// Something went wrong reading the file; the editor can't work on it.
    @Published private(set) var loadError: String?

    private var history: EditHistory
    private var tree: MusicXMLTree?

    init(document: ScoreDocument) {
        self.document = document
        self.musicXML = document.musicXML
        self.history = EditHistory(initial: document.musicXML)
        do {
            self.tree = try MusicXMLTree.parse(document.musicXML)
        } catch {
            self.tree = nil
            self.loadError = error.localizedDescription
        }
        refreshDerived()
    }

    // MARK: Derived state

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var isDirty: Bool { history.isDirty }
    var canEdit: Bool { tree != nil }

    var flaggedMeasureIndices: [Int] { issues.map { $0.measureIndex } }

    /// The selected note's element, if the selection is valid.
    private var selectedNote: MusicXMLElement? {
        guard let tree = tree, let selection = selection else { return nil }
        return ScoreEditing.note(at: selection, in: tree)
    }

    var selectedIsRest: Bool {
        selectedNote?.firstChild(named: "rest") != nil
    }

    var selectedIsTied: Bool {
        guard let note = selectedNote else { return false }
        return ScoreEditing.hasTie(note, type: "start")
    }

    var selectedHasDot: Bool {
        guard let note = selectedNote else { return false }
        return !note.children(named: "dot").isEmpty
    }

    /// The edited music as a document for the preview player and for saving.
    var correctedDocument: ScoreDocument {
        ScoreDocument(id: document.id,
                      title: document.title,
                      musicXML: musicXML,
                      origin: .edited,
                      instrument: document.instrument,
                      excerptId: document.excerptId,
                      preferredBPM: document.preferredBPM,
                      warnings: document.warnings)
    }

    // MARK: Selection

    /// A tap reported by the notation page.
    func select(tap: EditorNoteTap) {
        guard let tree = tree else { return }
        guard let measureIndex = EditorLogic.resolveMeasureIndex(tapIndex: tap.measureIndex,
                                                                 tapNumber: tap.measureNumber,
                                                                 measureNumbers: measureNumbers) else {
            hint = String(localized: "That bar couldn't be matched to the file.")
            return
        }
        if tap.noteOrder < 0 {
            hint = String(localized: "Only the top voice can be edited here.")
            return
        }
        let address = NoteAddress(measureIndex: measureIndex, noteIndex: tap.noteOrder)
        guard ScoreEditing.isValid(address, in: tree) else {
            hint = String(localized: "That note couldn't be matched to the file.")
            return
        }
        hint = nil
        selection = address
    }

    /// Selects the first editable note of a bar (from the "Bars to check" list).
    func selectFirstNote(inMeasure index: Int) {
        guard let tree = tree else { return }
        let address = NoteAddress(measureIndex: index, noteIndex: 0)
        if ScoreEditing.isValid(address, in: tree) {
            selection = address
            hint = nil
        } else {
            selection = nil
            let label: String = measureNumbers.indices.contains(index) ? measureNumbers[index] : String(index + 1)
            hint = String(localized: "Bar \(label) has no notes in the top voice. Tap a note in a bar next to it and use Insert.")
        }
    }

    func clearSelection() {
        selection = nil
    }

    func clearHint() {
        hint = nil
    }

    // MARK: Edits

    func apply(_ edit: ScoreEdit) {
        guard let tree = tree else { return }
        guard let address = selection else {
            hint = String(localized: "Tap a note first.")
            return
        }
        let working = tree.deepCopy()
        var newSelection: NoteAddress? = address
        do {
            switch edit {
            case .pitchUp:
                try ScoreEditing.transpose(address, by: 1, in: working)
            case .pitchDown:
                try ScoreEditing.transpose(address, by: -1, in: working)
            case .accidental(let choice):
                try ScoreEditing.setAccidental(address, choice, in: working)
            case .duration(let value):
                try ScoreEditing.setDuration(address, value, in: working)
            case .toggleDot:
                try ScoreEditing.toggleDot(address, in: working)
            case .toggleRest:
                try ScoreEditing.toggleRest(address, in: working)
            case .toggleTie:
                try ScoreEditing.toggleTie(address, in: working)
            case .insertAfter:
                newSelection = try ScoreEditing.insertNoteAfter(address, in: working)
            case .delete:
                try ScoreEditing.deleteNote(address, in: working)
                let remaining = ScoreEditing.measure(at: address.measureIndex, in: working)
                    .map { ScoreEditing.addressableNotes(in: $0).count } ?? 0
                newSelection = EditorLogic.selectionAfterDelete(address, remainingNotesInMeasure: remaining)
            }
        } catch {
            hint = error.localizedDescription
            return
        }
        hint = nil
        commit(working, selection: newSelection)
    }

    func undo() {
        guard let xml = history.undo() else { return }
        restore(xml)
    }

    func redo() {
        guard let xml = history.redo() else { return }
        restore(xml)
    }

    // MARK: Private

    private func commit(_ newTree: MusicXMLTree, selection newSelection: NoteAddress?) {
        tree = newTree
        let xml = newTree.serialized()
        history.push(xml)
        musicXML = xml
        refreshDerived()
        if let candidate = newSelection, ScoreEditing.isValid(candidate, in: newTree) {
            selection = candidate
        } else {
            selection = nil
        }
    }

    private func restore(_ xml: String) {
        do {
            let parsed = try MusicXMLTree.parse(xml)
            tree = parsed
            musicXML = xml
            refreshDerived()
            if let current = selection, !ScoreEditing.isValid(current, in: parsed) {
                selection = nil
            }
            hint = nil
        } catch {
            hint = error.localizedDescription
        }
    }

    private func refreshDerived() {
        guard let tree = tree else {
            issues = []
            measureNumbers = []
            return
        }
        issues = ScoreEditing.barCheck(in: tree)
        measureNumbers = ScoreEditing.measureNumbers(in: tree)
    }
}
