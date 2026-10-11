import XCTest
@testable import Auditioner

final class ToolsTests: XCTestCase {

    // MARK: - Metronome: click scheduling

    func testTickFrameAtBPMAndSampleRate() {
        // 120 BPM → 0.5 s per beat → beat 4 is at 2.0 s = 96 000 frames at 48 kHz.
        XCTAssertEqual(MetronomeMath.frame(ofTick: 4, bpm: 120, sampleRate: 48_000, subdivision: .none), 96_000)
        XCTAssertEqual(MetronomeMath.frame(ofTick: 0, bpm: 120, sampleRate: 48_000, subdivision: .none), 0)
        // 90 BPM at 44.1 kHz: one beat = 29 400 frames.
        XCTAssertEqual(MetronomeMath.frame(ofTick: 1, bpm: 90, sampleRate: 44_100, subdivision: .none), 29_400)
        // 60 BPM: tick 1000 is exactly 1000 s in.
        XCTAssertEqual(MetronomeMath.frame(ofTick: 1000, bpm: 60, sampleRate: 44_100, subdivision: .none), 44_100_000)
    }

    func testTickFrameWithSubdivisions() {
        // 120 BPM in 2: a tick every 0.25 s → tick 3 at 0.75 s = 36 000 frames at 48 kHz.
        XCTAssertEqual(MetronomeMath.frame(ofTick: 3, bpm: 120, sampleRate: 48_000, subdivision: .two), 36_000)
        // 100 BPM in 3: a tick every 0.2 s → tick 7 at 1.4 s = 67 200 frames.
        XCTAssertEqual(MetronomeMath.frame(ofTick: 7, bpm: 100, sampleRate: 48_000, subdivision: .three), 67_200)
        // In 4 at 300 BPM the ticks are 50 ms apart: longer than one click (30 ms), so clicks never overlap.
        let fastest = MetronomeMath.secondsPerTick(bpm: 300, subdivision: .four)
        XCTAssertEqual(fastest, 0.05, accuracy: 1e-12)
        XCTAssertLessThan(ClickSynth.lengthSeconds, fastest)
    }

    func testTickKindsAndBeatsInBar() {
        XCTAssertEqual(MetronomeMath.tickKind(tick: 0, beatsPerBar: 4, subdivision: .none, accentFirstBeat: true), .accent)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 1, beatsPerBar: 4, subdivision: .none, accentFirstBeat: true), .beat)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 4, beatsPerBar: 4, subdivision: .none, accentFirstBeat: true), .accent)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 0, beatsPerBar: 4, subdivision: .none, accentFirstBeat: false), .beat)

        XCTAssertEqual(MetronomeMath.tickKind(tick: 1, beatsPerBar: 4, subdivision: .two, accentFirstBeat: true), .subdivision)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 2, beatsPerBar: 4, subdivision: .two, accentFirstBeat: true), .beat)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 8, beatsPerBar: 4, subdivision: .two, accentFirstBeat: true), .accent)

        // Starting on beat 3 (0-based) of a 4-beat bar: the next tick is beat 0 again.
        XCTAssertEqual(MetronomeMath.beatInBar(tick: 0, beatsPerBar: 4, subdivision: .none, startBeat: 3), 3)
        XCTAssertEqual(MetronomeMath.beatInBar(tick: 1, beatsPerBar: 4, subdivision: .none, startBeat: 3), 0)
        XCTAssertEqual(MetronomeMath.tickKind(tick: 1, beatsPerBar: 4, subdivision: .none, accentFirstBeat: true, startBeat: 3), .accent)
        XCTAssertEqual(MetronomeMath.beatInBar(tick: 7, beatsPerBar: 3, subdivision: .two, startBeat: 0), 0)
    }

    func testBPMClamping() {
        XCTAssertEqual(MetronomeMath.clampBPM(10), 30)
        XCTAssertEqual(MetronomeMath.clampBPM(500), 300)
        XCTAssertEqual(MetronomeMath.clampBPM(120), 120)
        XCTAssertEqual(MetronomeMath.clampBPM(.nan), 30)
        XCTAssertEqual(MetronomeMath.clampBeatsPerBar(0), 1)
        XCTAssertEqual(MetronomeMath.clampBeatsPerBar(20), 12)
    }

    // MARK: - Metronome: tap tempo

    func testTapTempoAveragesTheLastFourTaps() {
        XCTAssertEqual(MetronomeMath.tapTempo(tapTimes: [0, 0.5, 1.0, 1.5, 2.0]), 120)
        // Only the last four taps count: the first interval (1 s) is ignored.
        XCTAssertEqual(MetronomeMath.tapTempo(tapTimes: [0, 1.0, 1.5, 2.0, 2.5]), 120)
        // Three taps at 0.75 s → 80 BPM.
        XCTAssertEqual(MetronomeMath.tapTempo(tapTimes: [10, 10.75, 11.5]), 80)
        XCTAssertEqual(MetronomeMath.tapTempo(tapTimes: [0, 0.5]), 120)
        XCTAssertNil(MetronomeMath.tapTempo(tapTimes: [0]))
        XCTAssertNil(MetronomeMath.tapTempo(tapTimes: []))
        // A long gap means a new measurement, not a very slow tempo.
        XCTAssertNil(MetronomeMath.tapTempo(tapTimes: [0, 5]))
        // Faster than the range → clamped.
        XCTAssertEqual(MetronomeMath.tapTempo(tapTimes: [0, 0.1, 0.2]), 300)
    }

    func testTrimmedTapsStartOverAfterAGap() {
        let taps = MetronomeMath.trimmedTaps([0, 0.5, 1.0], adding: 1.5)
        XCTAssertEqual(taps, [0, 0.5, 1.0, 1.5])
        XCTAssertEqual(MetronomeMath.trimmedTaps([0, 0.5, 1.0], adding: 9), [9])
        let many = MetronomeMath.trimmedTaps([1, 2, 3, 4, 5, 6, 7, 8], adding: 9)
        XCTAssertEqual(many.count, 8)
        XCTAssertEqual(many.last, 9)
    }

    func testTempoMarkingHintsAreRoughGuides() {
        XCTAssertEqual(MetronomeMath.tempoMarkingName(bpm: 100), "Andante")
        XCTAssertEqual(MetronomeMath.tempoMarkingName(bpm: 140), "Allegro")
        XCTAssertEqual(MetronomeMath.tempoMarkingName(bpm: 30), "Grave")
        XCTAssertEqual(MetronomeMath.tempoMarkingName(bpm: 300), "Prestissimo")
        XCTAssertTrue(MetronomeMath.tempoMarkingHint(bpm: 140).hasPrefix("Allegro"))
        XCTAssertTrue(MetronomeMath.tempoMarkingHint(bpm: 140).contains("120–168"))
    }

    func testMetronomePresetRoundTripAndTolerantDecoding() throws {
        let settings = MetronomeSettings(bpm: 132, beatsPerBar: 6, beatUnit: .eighth, subdivision: .three,
                                         accentFirstBeat: false, sound: .beep)
        let decoded = try XCTUnwrap(MetronomeSettings.decoded(from: settings.encoded()))
        XCTAssertEqual(decoded, settings)
        // Older presets with missing keys fall back to the defaults instead of failing.
        let partial = try XCTUnwrap(MetronomeSettings.decoded(from: Data("{\"bpm\": 96}".utf8)))
        XCTAssertEqual(partial.bpm, 96)
        XCTAssertEqual(partial.beatsPerBar, 4)
        XCTAssertEqual(partial.subdivision, Subdivision.none)
        XCTAssertNil(MetronomeSettings.decoded(from: Data()))
        // Out-of-range values are clamped on the way in.
        XCTAssertEqual(MetronomeSettings(bpm: 1000, beatsPerBar: 99).bpm, 300)
        XCTAssertEqual(MetronomeSettings(bpm: 1000, beatsPerBar: 99).beatsPerBar, 12)
    }

    func testPresetKeyPerExcerpt() {
        XCTAssertEqual(MetronomeMath.presetKey(excerptId: "cello-strauss-don-juan"), "metronome.preset.cello-strauss-don-juan")
        XCTAssertEqual(MetronomeMath.presetKey(excerptId: nil), "metronome.preset.default")
        XCTAssertEqual(MetronomeMath.presetKey(excerptId: "  "), "metronome.preset.default")
    }

    // MARK: - Click synthesis

    func testClickSamplesAreShortAndWithinRange() {
        for sound in ClickSound.allCases {
            for kind in [TickKind.accent, TickKind.beat, TickKind.subdivision] {
                let samples = ClickSynth.samples(sound: sound, kind: kind, sampleRate: 44_100)
                XCTAssertEqual(samples.count, 1323, "30 ms at 44.1 kHz")
                let peak = samples.map { abs($0) }.max() ?? 0
                XCTAssertLessThanOrEqual(peak, 1.0)
                XCTAssertGreaterThan(peak, 0.1, "\(sound) \(kind) should be audible")
                XCTAssertLessThan(abs(samples[0]), 0.05, "starts near silence so there is no click at the edge")
            }
        }
        // Same input, same output.
        XCTAssertEqual(ClickSynth.samples(sound: .woodblock, kind: .beat, sampleRate: 48_000),
                       ClickSynth.samples(sound: .woodblock, kind: .beat, sampleRate: 48_000))
        // Accents are louder than subdivisions.
        XCTAssertGreaterThan(ClickSynth.amplitude(for: .accent), ClickSynth.amplitude(for: .subdivision))
    }

    func testMeterPositionFromDecibels() {
        XCTAssertEqual(PCMBufferTools.meterPosition(decibels: -50), 0, accuracy: 1e-9)
        XCTAssertEqual(PCMBufferTools.meterPosition(decibels: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(PCMBufferTools.meterPosition(decibels: -25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PCMBufferTools.meterPosition(decibels: -160), 0, accuracy: 1e-9)
        XCTAssertEqual(PCMBufferTools.meterPosition(linearLevel: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(PCMBufferTools.meterPosition(linearLevel: 0), 0, accuracy: 1e-9)
    }

    // MARK: - Drone: pitch

    func testFrequencyOfPitchForTuning() {
        // A3 (the cello A string) is MIDI 57: 220 Hz at A = 440, 221 Hz at A = 442.
        XCTAssertEqual(DroneMath.frequency(midi: 57, a4: 440), 220, accuracy: 1e-9)
        XCTAssertEqual(DroneMath.frequency(midi: 57, a4: 442), 221, accuracy: 1e-9)
        XCTAssertEqual(DroneMath.frequency(midi: 69, a4: 440), 440, accuracy: 1e-9)
        XCTAssertEqual(DroneMath.frequency(midi: 60, a4: 440), 261.6256, accuracy: 1e-3)
        XCTAssertEqual(DroneMath.midi(pitchClass: .a, octave: 3), 57)
        XCTAssertEqual(DroneMath.midi(pitchClass: .c, octave: 4), 60)
        let a3 = DroneNote(pitchClass: .a, octave: 3)
        XCTAssertEqual(a3.midi, 57)
        XCTAssertEqual(a3.displayName, "A3")
        XCTAssertEqual(a3.fifthAbove, DroneNote(pitchClass: .e, octave: 4))
        XCTAssertEqual(DroneMath.note(midi: 57), a3)
        XCTAssertEqual(DroneMath.cents(forA4: 440), 0, accuracy: 1e-9)
        XCTAssertEqual(DroneMath.cents(forA4: 442), 7.85, accuracy: 0.01)
        XCTAssertEqual(DroneMath.frequency(midi: 69, a4: 0), 440, accuracy: 1e-9, "bad tuning falls back to 440")
    }

    // MARK: - Mock audition

    func testMockAuditionItemJSONRoundTrip() throws {
        let scoreId = UUID()
        let items = [
            MockAuditionItem(title: "Strauss · Don Juan — Opening", excerptId: "cello-strauss-don-juan",
                             scoreId: nil, startOffsetSeconds: 12.5, rating: 4),
            MockAuditionItem(title: "My scan", excerptId: nil, scoreId: scoreId, startOffsetSeconds: nil, rating: nil),
        ]
        let data = MockAuditionLogic.encode(items)
        XCTAssertFalse(data.isEmpty)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"startOffsetSeconds\":12.5"))
        XCTAssertTrue(json.contains("\"excerptId\":\"cello-strauss-don-juan\""))
        XCTAssertEqual(MockAuditionLogic.decode(data), items)
        XCTAssertEqual(MockAuditionLogic.decode(Data()), [])
        XCTAssertEqual(MockAuditionLogic.decode(Data("not json".utf8)), [])
    }

    func testRandomOrderKeepsEveryItemOnce() {
        let items = (1...8).map { MockAuditionItem(title: "Excerpt \($0)", excerptId: "e\($0)") }
        var generator = SeededRandomNumberGenerator(seed: 42)
        let shuffled = MockAuditionLogic.ordered(items, order: .random, using: &generator)
        XCTAssertEqual(shuffled.count, items.count)
        XCTAssertEqual(Set(shuffled.map { $0.title }), Set(items.map { $0.title }))
        XCTAssertEqual(shuffled.map { $0.title }.sorted(), items.map { $0.title }.sorted())
        XCTAssertEqual(MockAuditionLogic.ordered(items, order: .asListed, using: &generator), items)
        // The same seed gives the same order; a different seed (almost surely) another.
        var again = SeededRandomNumberGenerator(seed: 42)
        XCTAssertEqual(MockAuditionLogic.ordered(items, order: .random, using: &again), shuffled)
        XCTAssertEqual(MockAuditionLogic.ordered([], order: .random).count, 0)
    }

    func testHiddenTitlesAndRatings() {
        XCTAssertEqual(MockAuditionLogic.hiddenTitle(index: 1, count: 6), "Excerpt 2 of 6")
        let item = MockAuditionItem(title: "Brahms · Symphony No. 2")
        XCTAssertEqual(MockAuditionLogic.displayTitle(for: item, index: 0, count: 3, hideTitles: true), "Excerpt 1 of 3")
        XCTAssertEqual(MockAuditionLogic.displayTitle(for: item, index: 0, count: 3, hideTitles: false), item.title)
        XCTAssertEqual(MockAuditionLogic.clampRating(9), 5)
        XCTAssertEqual(MockAuditionLogic.clampRating(0), 1)
        XCTAssertNil(MockAuditionLogic.clampRating(nil))
        let rated = [MockAuditionItem(title: "a", rating: 3), MockAuditionItem(title: "b", rating: 5), MockAuditionItem(title: "c")]
        XCTAssertEqual(try XCTUnwrap(MockAuditionLogic.averageRating(rated)), 4, accuracy: 1e-9)
        XCTAssertNil(MockAuditionLogic.averageRating([MockAuditionItem(title: "c")]))
    }

    // MARK: - Take files

    func testTakeFileNaming() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 11
        components.hour = 14
        components.minute = 30
        components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.timeZone = utc
        let date = try XCTUnwrap(calendar.date(from: components))

        XCTAssertEqual(TakeStore.fileName(title: "Strauss · Don Juan", date: date, timeZone: utc),
                       "Strauss-Don-Juan-20261011-143005.m4a")
        XCTAssertEqual(TakeStore.fileName(title: "", date: date, timeZone: utc), "Take-20261011-143005.m4a")
        XCTAssertEqual(TakeStore.fileName(title: "···", date: date, timeZone: utc), "Take-20261011-143005.m4a")
        XCTAssertEqual(TakeStore.sanitizedBase("Demo: D major scale"), "Demo-D-major-scale")
        XCTAssertLessThanOrEqual(TakeStore.sanitizedBase(String(repeating: "a", count: 200)).count, 60)

        let taken: Set<String> = ["Take-1.m4a", "Take-1-2.m4a"]
        XCTAssertEqual(TakeStore.uniqueFileName(preferred: "Take-1.m4a", exists: { taken.contains($0) }), "Take-1-3.m4a")
        XCTAssertEqual(TakeStore.uniqueFileName(preferred: "Fresh.m4a", exists: { taken.contains($0) }), "Fresh.m4a")
        XCTAssertTrue(TakeStore.directory.path.hasSuffix("/Takes"))
    }

    // MARK: - Record & compare: timeline inverse

    func testBeatAtSecondsInvertsSecondsAtBeat() {
        let measures = [
            Measure(number: "1", startBeat: 0, lengthBeats: 4, notes: []),
            Measure(number: "2", startBeat: 4, lengthBeats: 4, notes: []),
            Measure(number: "3", startBeat: 8, lengthBeats: 4, notes: []),
        ]
        let steady = PlaybackTimeline(score: Score(measures: measures, tempoChanges: [TempoChange(beat: 0, bpm: 80)]),
                                      transposition: 0)
        XCTAssertEqual(steady.seconds(atBeat: 4, targetBPM: 80), 3, accuracy: 1e-9)
        XCTAssertEqual(steady.beat(atSeconds: 3, targetBPM: 80), 4, accuracy: 1e-9)
        XCTAssertEqual(steady.beat(atSeconds: 0, targetBPM: 80), 0, accuracy: 1e-9)
        XCTAssertEqual(steady.beat(atSeconds: 100, targetBPM: 80), 12, accuracy: 1e-9, "clamped to the end")
        // Slowed down to 40: twice as long.
        XCTAssertEqual(steady.beat(atSeconds: 3, targetBPM: 40), 2, accuracy: 1e-9)

        // A tempo change at beat 6: 120 → 90. Beat 8 = 6 beats at 120 (3 s) + 2 beats at 90 (1.333 s).
        let changing = PlaybackTimeline(score: Score(measures: measures,
                                                     tempoChanges: [TempoChange(beat: 0, bpm: 120), TempoChange(beat: 6, bpm: 90)]),
                                        transposition: 0)
        let seconds = changing.seconds(atBeat: 8, targetBPM: 120)
        XCTAssertEqual(seconds, 3 + 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(changing.beat(atSeconds: seconds, targetBPM: 120), 8, accuracy: 1e-9)
        XCTAssertEqual(changing.beat(atSeconds: 1.5, targetBPM: 120), 3, accuracy: 1e-9)
        for beat in stride(from: 0.0, through: 12.0, by: 0.5) {
            let t = changing.seconds(atBeat: beat, targetBPM: 100)
            XCTAssertEqual(changing.beat(atSeconds: t, targetBPM: 100), beat, accuracy: 1e-6)
        }
    }

    func testCompareMixAndRateLabels() {
        XCTAssertEqual(CompareMix.allCases.count, 3)
        XCTAssertEqual(TakePlayer.rateLabel(1.0), "1×")
        XCTAssertEqual(TakePlayer.rateLabel(0.5), "0.5×")
        XCTAssertEqual(TakePlayer.rateChoices.first, 0.5)
        XCTAssertEqual(TakePlayer.rateChoices.last, 1.0)
    }
}
