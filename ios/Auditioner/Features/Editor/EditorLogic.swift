import Foundation

/// Plain helpers for the correction editor (no SwiftUI, so tests can call them directly).
enum EditorLogic {
    /// Measure index for a tap reported by the notation page: the page's measure index when it
    /// agrees with the printed number (or no number is known), otherwise a lookup by number.
    static func resolveMeasureIndex(tapIndex: Int, tapNumber: String, measureNumbers: [String]) -> Int? {
        if tapIndex >= 0, tapIndex < measureNumbers.count {
            if tapNumber.isEmpty || measureNumbers[tapIndex] == tapNumber {
                return tapIndex
            }
        }
        if !tapNumber.isEmpty, let found = measureNumbers.firstIndex(of: tapNumber) {
            return found
        }
        return nil
    }

    /// What to select after a note was deleted: the note that moved into its place, else the one before, else nothing.
    static func selectionAfterDelete(_ address: NoteAddress, remainingNotesInMeasure count: Int) -> NoteAddress? {
        if count <= 0 { return nil }
        if address.noteIndex < count { return address }
        return NoteAddress(measureIndex: address.measureIndex, noteIndex: count - 1)
    }

    /// "Brahms 2 · bars 1–20" → "Brahms 2 · bars 1–20 (corrected)" (not doubled on a second round).
    static func correctedTitle(_ title: String) -> String {
        let suffix = String(localized: " (corrected)")
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(suffix) { return trimmed }
        return trimmed + suffix
    }

    /// "3½" / "2¼" / "4" / "2.7" for beat counts.
    static func beatsText(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let fraction = value - whole
        let wholeText = whole > 0 ? String(Int(whole)) : ""
        let eps = 1e-6
        var fractionText = ""
        if abs(fraction - 0.5) < eps {
            fractionText = "½"
        } else if abs(fraction - 0.25) < eps {
            fractionText = "¼"
        } else if abs(fraction - 0.75) < eps {
            fractionText = "¾"
        } else if abs(fraction) < eps {
            fractionText = ""
        } else if abs(fraction - 1.0 / 3.0) < 1e-3 {
            fractionText = "⅓"
        } else if abs(fraction - 2.0 / 3.0) < 1e-3 {
            fractionText = "⅔"
        } else {
            return String(format: "%.2f", value)
        }
        if wholeText.isEmpty && fractionText.isEmpty { return "0" }
        return wholeText + fractionText
    }

    /// "Bar 3: 3½ of 4 beats"
    static func issueText(_ issue: BarCheckIssue) -> String {
        let actual = beatsText(issue.actualBeats)
        let expected = beatsText(issue.expectedBeats)
        return String(localized: "Bar \(issue.measureNumber): \(actual) of \(expected) beats")
    }
}
