import SwiftUI

/// "Mark start" / "Mark end", the user's own marks and "Jump to my start". Shared by the
/// YouTube and hosted players; the parent supplies the current time.
struct RecordingMarkControls: View {
    @ObservedObject var marks: RecordingMarks
    let onMarkStart: () -> Void
    let onMarkEnd: () -> Void
    let onJumpToStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    onMarkStart()
                } label: {
                    Label("Mark start", systemImage: "flag")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    onMarkEnd()
                } label: {
                    Label("Mark end", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            if marks.start != nil || marks.end != nil {
                HStack(spacing: 12) {
                    Text(myMarksText)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                    Spacer(minLength: 0)
                    if marks.start != nil {
                        Button("Jump to my start") {
                            onJumpToStart()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let error = marks.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.garnet)
            }
        }
    }

    private var myMarksText: String {
        let start: String = marks.start.map { MediaTimeFormatter.mmss($0) } ?? "–"
        let end: String = marks.end.map { MediaTimeFormatter.mmss($0) } ?? "–"
        return String(localized: "My marks: \(start) – \(end)")
    }
}

/// Playback speed menu built from the rates the player offers.
struct RecordingSpeedMenu: View {
    let rates: [Double]
    let currentRate: Double
    let isEnabled: Bool
    let onSelect: (Double) -> Void

    var body: some View {
        Menu {
            ForEach(rates, id: \.self) { rate in
                Button {
                    onSelect(rate)
                } label: {
                    if abs(rate - currentRate) < 0.001 {
                        Label(ExcerptFormat.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(ExcerptFormat.rateLabel(rate))
                    }
                }
            }
        } label: {
            Label("Speed \(ExcerptFormat.rateLabel(currentRate))", systemImage: "speedometer")
        }
        .disabled(!isEnabled || rates.isEmpty)
    }
}

/// The verified-start status line shared by the players.
struct RecordingStartStatusLine: View {
    let verifiedStart: Double?

    var body: some View {
        if let start = verifiedStart {
            Label("Starts at \(MediaTimeFormatter.mmss(start)) (checked)", systemImage: "checkmark.seal")
                .font(.subheadline)
                .foregroundStyle(Theme.teal)
        } else {
            Label("Start time not confirmed yet — play and tap Mark start", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

/// Shown when a recording cannot be played inside the app at all.
struct RecordingUnavailableView: View {
    let recording: Recording
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            if let urlString = recording.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Open recording", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// A recording that lives on another service (IDAGIO, Presto, medici.tv, ...): just a link out.
struct LinkRecordingView: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            if let performer = recording.performer, !performer.isEmpty {
                Text(performer)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            RecordingStartStatusLine(verifiedStart: recording.start?.verifiedValue)
            if let urlString = recording.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Open recording", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("This recording has no link yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }
}
