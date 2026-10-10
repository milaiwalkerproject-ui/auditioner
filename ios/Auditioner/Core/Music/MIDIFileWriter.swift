import Foundation

/// Writes a Standard MIDI File (format 1, 480 ticks per quarter note) from a `PlaybackTimeline`.
///
/// Tracks, in file order:
///   0. tempo track — set-tempo and time-signature meta events only
///   1. note track — program change + notes on channel 0
///   2. click track (optional) — count-in clicks on channel 9 (woodblock 76 on downbeats, 77 otherwise)
///
/// With a count-in, the music is shifted later by the count-in length.
/// Every event carries its own status byte (no running status).
enum MIDIFileWriter {
    static let ticksPerQuarter: Int = 480
    static let noteChannel: UInt8 = 0
    static let clickChannel: UInt8 = 9
    static let downbeatClickKey: UInt8 = 76
    static let clickKey: UInt8 = 77

    struct CountIn: Equatable {
        /// Clicks in one bar (the time signature's numerator).
        var clicksPerBar: Int
        /// Quarter notes between clicks (4 / beat-type).
        var clickSpacingBeats: Double
        var bars: Int

        /// Total count-in length in quarter notes.
        var totalBeats: Double {
            Double(clicksPerBar * bars) * clickSpacingBeats
        }

        var clickCount: Int { clicksPerBar * bars }
    }

    struct Result {
        var data: Data
        /// Quarter notes the music was shifted by (0 without count-in).
        var countInBeats: Double
        var hasClickTrack: Bool
    }

    /// One raw event in a track, before delta-time encoding.
    private struct RawEvent {
        var tick: Int
        /// Lower sorts first at equal ticks (meta 0, note-off 1, program 2, note-on 3).
        var priority: Int
        var order: Int
        var bytes: [UInt8]
    }

    // MARK: Public API

    static func write(timeline: PlaybackTimeline, program: UInt8, baseBPM: Double, countIn: CountIn?) -> Result {
        let offsetBeats: Double = countIn.map { $0.totalBeats } ?? 0
        let offsetTicks: Int = ticks(forBeat: offsetBeats)

        var tracks: [Data] = []
        tracks.append(tempoTrack(timeline: timeline, baseBPM: baseBPM, offsetTicks: offsetTicks, countIn: countIn))
        tracks.append(noteTrack(timeline: timeline, program: program, offsetTicks: offsetTicks))
        if let countIn = countIn, countIn.clickCount > 0 {
            tracks.append(clickTrack(countIn: countIn))
        }

        var data = Data()
        data.append(header(trackCount: tracks.count))
        for track in tracks {
            data.append(track)
        }
        return Result(data: data, countInBeats: offsetBeats, hasClickTrack: countIn != nil && (countIn?.clickCount ?? 0) > 0)
    }

    /// Variable-length quantity encoding (7 bits per byte, high bit set on all but the last byte).
    static func vlq(_ value: UInt32) -> [UInt8] {
        var v: UInt32 = value & 0x0FFF_FFFF
        var buffer: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            buffer.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return buffer
    }

    static func ticks(forBeat beat: Double) -> Int {
        Int((beat * Double(ticksPerQuarter)).rounded())
    }

    /// Microseconds per quarter note for a tempo.
    static func microsecondsPerQuarter(bpm: Double) -> UInt32 {
        let clamped = max(1.0, min(1000.0, bpm))
        return UInt32((60_000_000.0 / clamped).rounded())
    }

    // MARK: Chunks

    static func header(trackCount: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("MThd".utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x06])
        bytes.append(contentsOf: [0x00, 0x01])                       // format 1
        bytes.append(contentsOf: uint16BE(UInt16(trackCount)))
        bytes.append(contentsOf: uint16BE(UInt16(ticksPerQuarter)))  // 0x01E0
        return Data(bytes)
    }

    private static func uint16BE(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func trackChunk(events: [RawEvent]) -> Data {
        let sorted = events.sorted { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.order < b.order
        }
        var body: [UInt8] = []
        var lastTick = 0
        for event in sorted {
            let tick = max(event.tick, lastTick)
            let delta = UInt32(tick - lastTick)
            body.append(contentsOf: vlq(delta))
            body.append(contentsOf: event.bytes)
            lastTick = tick
        }
        // End of track.
        body.append(contentsOf: vlq(0))
        body.append(contentsOf: [0xFF, 0x2F, 0x00])

        var chunk: [UInt8] = []
        chunk.append(contentsOf: Array("MTrk".utf8))
        chunk.append(contentsOf: uint32BE(UInt32(body.count)))
        chunk.append(contentsOf: body)
        return Data(chunk)
    }

    private static func tempoTrack(timeline: PlaybackTimeline, baseBPM: Double, offsetTicks: Int, countIn: CountIn?) -> Data {
        var events: [RawEvent] = []
        var order = 0

        // Time signature of the count-in / first bar.
        let ts = timeline.firstTimeSignature ?? TimeSignatureChange(beat: 0, beats: 4, beatType: 4)
        events.append(RawEvent(tick: 0, priority: 0, order: order, bytes: timeSignatureMeta(ts)))
        order += 1

        let map = timeline.tempoMap(baseBPM: baseBPM)
        for (index, change) in map.enumerated() {
            let tick = index == 0 ? 0 : offsetTicks + ticks(forBeat: change.beat)
            events.append(RawEvent(tick: tick, priority: 0, order: order, bytes: tempoMeta(bpm: change.bpm)))
            order += 1
        }
        return trackChunk(events: events)
    }

    private static func noteTrack(timeline: PlaybackTimeline, program: UInt8, offsetTicks: Int) -> Data {
        var events: [RawEvent] = []
        var order = 0
        events.append(RawEvent(tick: 0, priority: 2, order: order, bytes: [0xC0 | noteChannel, program & 0x7F]))
        order += 1

        for event in timeline.events {
            let onTick = offsetTicks + ticks(forBeat: event.startBeat)
            var offTick = offsetTicks + ticks(forBeat: event.endBeat)
            if offTick <= onTick { offTick = onTick + 1 }
            let key = event.midiSounding & 0x7F
            events.append(RawEvent(tick: onTick, priority: 3, order: order, bytes: [0x90 | noteChannel, key, 96]))
            order += 1
            events.append(RawEvent(tick: offTick, priority: 1, order: order, bytes: [0x80 | noteChannel, key, 64]))
            order += 1
        }
        return trackChunk(events: events)
    }

    private static func clickTrack(countIn: CountIn) -> Data {
        var events: [RawEvent] = []
        var order = 0
        let clickLengthBeats = min(0.25, max(0.05, countIn.clickSpacingBeats / 2))
        for i in 0..<countIn.clickCount {
            let beat = Double(i) * countIn.clickSpacingBeats
            let onTick = ticks(forBeat: beat)
            var offTick = ticks(forBeat: beat + clickLengthBeats)
            if offTick <= onTick { offTick = onTick + 1 }
            let isDownbeat = (countIn.clicksPerBar > 0) && (i % countIn.clicksPerBar == 0)
            let key: UInt8 = isDownbeat ? downbeatClickKey : clickKey
            let velocity: UInt8 = isDownbeat ? 110 : 90
            events.append(RawEvent(tick: onTick, priority: 3, order: order, bytes: [0x90 | clickChannel, key, velocity]))
            order += 1
            events.append(RawEvent(tick: offTick, priority: 1, order: order, bytes: [0x80 | clickChannel, key, 64]))
            order += 1
        }
        return trackChunk(events: events)
    }

    // MARK: Meta events

    static func tempoMeta(bpm: Double) -> [UInt8] {
        let micros = microsecondsPerQuarter(bpm: bpm)
        return [0xFF, 0x51, 0x03,
                UInt8((micros >> 16) & 0xFF), UInt8((micros >> 8) & 0xFF), UInt8(micros & 0xFF)]
    }

    static func timeSignatureMeta(_ ts: TimeSignatureChange) -> [UInt8] {
        var d = max(1, ts.beatType)
        var power = 0
        while d > 1 {
            d /= 2
            power += 1
        }
        let denominatorPower = UInt8(min(7, power))
        let numerator = UInt8(max(1, min(255, ts.beats)))
        return [0xFF, 0x58, 0x04, numerator, denominatorPower, 24, 8]
    }
}
