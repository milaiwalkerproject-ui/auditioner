import Foundation

/// "1:23" style times for the recording players. Unit-tested.
enum MediaTimeFormatter {
    /// m:ss, or h:mm:ss from one hour. Negative, NaN and infinite values show as "0:00".
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Whole seconds for a YouTube `t=` parameter (never negative).
    static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded(.down))
    }

    /// The second to cue an embedded YouTube player to: one second before the verified start,
    /// because seeks snap to keyframes.
    static func youtubeCueSecond(verifiedStart: Double) -> Int {
        max(0, wholeSeconds(verifiedStart - 1))
    }
}
