import SwiftUI

/// 1–5 star self-rating. Tapping the current star clears it.
struct RatingStars: View {
    @Binding var rating: Int?
    var font: Font = .title3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rating = (rating == star) ? nil : star
                } label: {
                    Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                        .font(font)
                        .foregroundStyle(Theme.brass)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(star) of 5"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Rating"))
    }
}

/// Horizontal input-level bar, 0…1.
struct LevelMeterBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.inkFaint.opacity(0.25))
                Capsule()
                    .fill(level > 0.92 ? Theme.garnet : Theme.teal)
                    .frame(width: max(0, min(1, level)) * geometry.size.width)
            }
        }
        .frame(height: 8)
        .accessibilityLabel(Text("Input level"))
        .accessibilityValue(Text("\(Int((max(0, min(1, level)) * 100).rounded())) percent"))
    }
}

/// Full-width start/stop button shared by the tools.
struct ToolStartStopButton: View {
    let isRunning: Bool
    let startTitle: String
    let stopTitle: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isRunning ? stopTitle : startTitle, systemImage: isRunning ? "stop.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRunning ? Theme.garnet : Theme.teal)
        .disabled(!isEnabled)
    }
}

/// Rounded card with an optional title, on the paper background.
struct ToolCard<Content: View>: View {
    let title: String?
    let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "1:23" in monospaced digits.
struct TimeText: View {
    let seconds: Double
    var font: Font = .body

    var body: some View {
        Text(MediaTimeFormatter.mmss(seconds))
            .font(font.monospacedDigit())
    }
}

/// Play/pause, position slider and speed menu for a `TakePlayer`.
struct TakePlayerControls: View {
    @ObservedObject var player: TakePlayer
    @State private var scrubSeconds: Double = 0
    @State private var isScrubbing: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
                .disabled(!player.isLoaded)

                TimeText(seconds: isScrubbing ? scrubSeconds : player.currentSeconds, font: .subheadline)
                    .foregroundStyle(Theme.inkSoft)
                Slider(value: sliderBinding, in: 0...max(0.01, player.durationSeconds)) { editing in
                    if editing {
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        player.seek(to: scrubSeconds)
                    }
                }
                .accessibilityLabel(Text("Position"))
                .disabled(!player.isLoaded)
                TimeText(seconds: player.durationSeconds, font: .subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            HStack {
                Text("Speed")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                Picker(selection: $player.rate) {
                    ForEach(TakePlayer.rateChoices, id: \.self) { value in
                        Text(TakePlayer.rateLabel(value)).tag(value)
                    }
                } label: {
                    Text("Speed")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Playback speed"))
            }
            if let message = player.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.garnet)
            }
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isScrubbing ? scrubSeconds : player.currentSeconds },
            set: { newValue in scrubSeconds = newValue }
        )
    }
}
