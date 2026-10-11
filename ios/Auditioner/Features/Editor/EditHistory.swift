import Foundation

/// Undo/redo over serialized MusicXML states. The first state is the untouched file.
struct EditHistory: Equatable {
    static let maximumStates = 100

    private(set) var states: [String]
    private(set) var index: Int
    /// The file as it was opened, kept even when old states are dropped.
    let initial: String

    init(initial: String) {
        self.states = [initial]
        self.index = 0
        self.initial = initial
    }

    var current: String { states[index] }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < states.count - 1 }
    /// `true` when the current state differs from the file as opened.
    var isDirty: Bool { current != initial }

    /// Records a new state after the current one; anything that could be redone is dropped.
    /// A state identical to the current one is ignored.
    mutating func push(_ state: String) {
        if state == current { return }
        if index < states.count - 1 {
            states.removeSubrange((index + 1)...)
        }
        states.append(state)
        if states.count > EditHistory.maximumStates {
            states.removeFirst(states.count - EditHistory.maximumStates)
        }
        index = states.count - 1
    }

    /// Steps back; returns the state to show, or `nil` at the beginning.
    mutating func undo() -> String? {
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    /// Steps forward; returns the state to show, or `nil` at the end.
    mutating func redo() -> String? {
        guard canRedo else { return nil }
        index += 1
        return current
    }
}
