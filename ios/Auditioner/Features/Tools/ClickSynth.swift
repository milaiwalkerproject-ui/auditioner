import Foundation
import AVFoundation

/// The metronome's click sound, generated in code (no sample files).
enum ClickSound: String, Codable, CaseIterable, Identifiable {
    case woodblock
    case beep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .woodblock: return String(localized: "Woodblock")
        case .beep: return String(localized: "Beep")
        }
    }
}

/// What kind of tick is sounding.
enum TickKind: Equatable, Hashable {
    case accent
    case beat
    case subdivision
}

/// Renders short click sounds as PCM samples. Pure functions: the same input always gives the same samples.
enum ClickSynth {
    /// Length of every click. Shorter than the fastest tick (300 BPM ÷ 4 = 50 ms) so clicks never overlap.
    static let lengthSeconds: Double = 0.03

    /// Mono Float32 samples of one click at `sampleRate`.
    static func samples(sound: ClickSound, kind: TickKind, sampleRate: Double) -> [Float] {
        let rate = sampleRate > 0 ? sampleRate : 44_100
        let count = max(1, Int((lengthSeconds * rate).rounded()))
        var out = [Float](repeating: 0, count: count)
        let amplitude: Double = ClickSynth.amplitude(for: kind)

        switch sound {
        case .woodblock:
            let f1: Double = ClickSynth.woodblockFrequency(for: kind)
            let f2: Double = f1 * 1.5
            let decay: Double = 0.006
            for i in 0..<count {
                let t = Double(i) / rate
                let attack = min(1.0, t / 0.0008)
                let envelope = exp(-t / decay) * attack
                let value = (0.7 * sin(2 * Double.pi * f1 * t) + 0.3 * sin(2 * Double.pi * f2 * t)) * envelope
                out[i] = Float(value * amplitude)
            }
        case .beep:
            let f: Double = ClickSynth.beepFrequency(for: kind)
            let attack: Double = 0.002
            let releaseStart: Double = lengthSeconds - 0.008
            for i in 0..<count {
                let t = Double(i) / rate
                var envelope: Double = 1
                if t < attack {
                    envelope = t / attack
                } else if t > releaseStart {
                    envelope = max(0, (lengthSeconds - t) / (lengthSeconds - releaseStart))
                }
                out[i] = Float(sin(2 * Double.pi * f * t) * envelope * amplitude * 0.8)
            }
        }
        return out
    }

    /// The click as a buffer in `format` (mono or stereo Float32, non-interleaved).
    static func buffer(sound: ClickSound, kind: TickKind, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let values = samples(sound: sound, kind: kind, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(values.count)
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for i in 0..<values.count {
                pointer[i] = values[i]
            }
        }
        return buffer
    }

    static func amplitude(for kind: TickKind) -> Double {
        switch kind {
        case .accent: return 0.95
        case .beat: return 0.75
        case .subdivision: return 0.4
        }
    }

    static func woodblockFrequency(for kind: TickKind) -> Double {
        switch kind {
        case .accent: return 2200
        case .beat: return 1700
        case .subdivision: return 1300
        }
    }

    static func beepFrequency(for kind: TickKind) -> Double {
        switch kind {
        case .accent: return 1320
        case .beat: return 1000
        case .subdivision: return 800
        }
    }
}

/// Buffer helpers shared by the recorder and the players.
enum PCMBufferTools {
    /// A copy of `buffer` without its first `frames` frames (Float32 non-interleaved only; `nil` otherwise).
    static func droppingFirst(_ frames: Int, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let total = Int(buffer.frameLength)
        guard frames >= 0, frames < total, let source = buffer.floatChannelData else { return nil }
        let remaining = total - frames
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remaining)),
              let destination = copy.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        for channel in 0..<channels {
            let from = source[channel]
            let to = destination[channel]
            for i in 0..<remaining {
                to[i] = from[frames + i]
            }
        }
        copy.frameLength = AVAudioFrameCount(remaining)
        return copy
    }

    /// Root-mean-square level of the first channel, 0…1 (0 for empty or non-float buffers).
    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Double {
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return 0 }
        let pointer = channels[0]
        var sum: Double = 0
        for i in 0..<count {
            let v = Double(pointer[i])
            sum += v * v
        }
        return min(1, sqrt(sum / Double(count)))
    }

    /// Maps a level (0…1, linear) to a meter position 0…1 using decibels: −50 dB → 0, 0 dB → 1.
    static func meterPosition(linearLevel: Double) -> Double {
        guard linearLevel > 0 else { return 0 }
        let decibels = 20 * log10(linearLevel)
        return meterPosition(decibels: decibels)
    }

    /// Maps decibels (−∞…0) to a meter position 0…1: −50 dB → 0, 0 dB → 1.
    static func meterPosition(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return max(0, min(1, (decibels + 50) / 50))
    }
}
