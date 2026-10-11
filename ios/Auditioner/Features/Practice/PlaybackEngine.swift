import Foundation
import AVFoundation
import AudioToolbox
import Combine

enum PlaybackEngineError: Error, LocalizedError {
    case notReady
    case soundBankMissing
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return String(localized: "The music isn't ready to play yet.")
        case .soundBankMissing:
            return String(localized: "The app's sound file is missing, so there's no sound. Reinstalling the app should fix it.")
        case .renderFailed(let detail):
            return String(localized: "The audio file couldn't be made (\(detail)).")
        }
    }
}

/// Reference-audio player for one `ScoreDocument`: AVAudioEngine + two samplers (instrument, clicks)
/// driven by an AVAudioSequencer playing a MIDI file built from the score.
///
/// Call everything on the main thread. Beats are quarter notes; `currentBeat` excludes the count-in.
final class PlaybackEngine: ObservableObject {

    // MARK: Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var isPlaying: Bool = false
    /// Position in the music, in quarter notes (0 during the count-in).
    @Published private(set) var currentBeat: Double = 0
    /// `true` while the count-in clicks are playing.
    @Published private(set) var isCountingIn: Bool = false
    /// Target tempo (quarter notes per minute).
    @Published var tempoBPM: Double = PlaybackTimeline.defaultBPM {
        didSet { applyRate() }
    }
    /// Tempo the MIDI sequence was written at; the playback rate is `tempoBPM / baseBPM`.
    @Published private(set) var baseBPM: Double = PlaybackTimeline.defaultBPM
    @Published var loopEnabled: Bool = false
    /// 0-based measure indices (see `measureNumbers` for the printed numbers).
    @Published var loopStartMeasure: Int = 0 {
        didSet { clampLoopStart() }
    }
    @Published var loopEndMeasure: Int = 0 {
        didSet { clampLoopEnd() }
    }
    @Published var countInEnabled: Bool = false {
        didSet { if oldValue != countInEnabled { rebuildSequence(keepPosition: true) } }
    }
    /// Tuning of A4 in Hz (440, 442 ...).
    @Published var a4: Double = 440 {
        didSet { applyTuning() }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var isExporting: Bool = false

    // MARK: Model

    let document: ScoreDocument
    private(set) var score: Score?
    private(set) var timeline: PlaybackTimeline?
    /// Semitones added to the written pitch (instrument transposition or the part's `<transpose>`).
    private(set) var transposition: Int = 0

    var measureNumbers: [String] { timeline?.measureNumbers ?? [] }
    var measureCount: Int { timeline?.measureCount ?? 0 }
    var totalBeats: Double { timeline?.totalBeats ?? 0 }

    func measureLabel(forIndex index: Int) -> String {
        let numbers = measureNumbers
        guard !numbers.isEmpty else { return "–" }
        let i = max(0, min(numbers.count - 1, index))
        return numbers[i]
    }

    // MARK: Audio objects

    private let engine = AVAudioEngine()
    private let instrumentSampler = AVAudioUnitSampler()
    private let clickSampler = AVAudioUnitSampler()
    private var sequencer: AVAudioSequencer?
    private var pollTimer: Timer?
    private var countInBeats: Double = 0
    private var soundBankURL: URL?
    private var soundBankLoaded = false
    private var observers: [NSObjectProtocol] = []
    private var prepared = false
    private var isClampingLoop = false
    private var wasPlayingBeforeInterruption = false
    private var engineConfigured = false

    private var usesPercussionBank: Bool { document.instrument == .percussion }
    private var program: UInt8 { usesPercussionBank ? 0 : document.instrument.gmProgram }

    // MARK: Lifecycle

    init(document: ScoreDocument) {
        self.document = document
        self.soundBankURL = Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2")
    }

    deinit {
        pollTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        sequencer?.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Parses the score, loads the sounds and builds the sequence. Safe to call more than once.
    func prepare() {
        guard !prepared else { return }
        prepared = true

        do {
            let parsed = try MusicXMLParser.parse(document.musicXML)
            score = parsed
            transposition = PlaybackTimeline.soundingTransposition(for: document.instrument, score: parsed)
            let built = PlaybackTimeline(score: parsed, transposition: transposition, preferredBPM: document.preferredBPM)
            timeline = built
            baseBPM = built.initialBPM
            tempoBPM = built.initialBPM
            loopStartMeasure = 0
            loopEndMeasure = max(0, built.measureCount - 1)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        configureEngineIfNeeded()
        registerObservers()
        loadSoundBank { [weak self] in
            guard let self = self else { return }
            self.rebuildSequence(keepPosition: false)
            self.applyTuning()
            self.isReady = true
        }
    }

    /// Stops playback and releases the audio hardware (call when the screen goes away).
    func shutdown() {
        pause()
        sequencer = nil
        if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Transport

    func play() {
        if sequencer == nil {
            // After shutdown() the sequence is gone; build it again.
            rebuildSequence(keepPosition: false)
        }
        guard let sequencer = sequencer else { return }
        do {
            try activateSession()
            try ensureEngineRunning()
            try sequencer.start()
        } catch {
            errorMessage = String(localized: "Playback couldn't start (\(error.localizedDescription)).")
            return
        }
        isPlaying = true
        TrendsTracker.shared.notePractised(excerptId: document.excerptId, instrument: document.instrument) // D6, only while sharing is on
        startPolling()
        poll()
    }

    func pause() {
        if let sequencer = sequencer, sequencer.isPlaying {
            sequencer.stop()
        }
        allNotesOff()
        stopPolling()
        isPlaying = false
        isCountingIn = false
        updateCurrentBeatFromSequencer()
    }

    /// Stop and go back to the start (the count-in plays again on the next play).
    func stop() {
        pause()
        seek(toBeat: 0)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Jump to a beat of the music (quarter notes from the start, count-in excluded).
    func seek(toBeat beat: Double) {
        guard let timeline = timeline else { return }
        let clamped = max(0, min(timeline.totalBeats, beat))
        if let sequencer = sequencer {
            sequencer.currentPositionInBeats = clamped <= 0 ? 0 : countInBeats + clamped
        }
        allNotesOff()
        currentBeat = clamped
        isCountingIn = false
    }

    /// "Play from here": start playing at a beat of the music (no count-in).
    func play(fromBeat beat: Double) {
        guard timeline != nil else { return }
        if isPlaying {
            seek(toBeat: beat)
        } else {
            seek(toBeat: beat)
            play()
        }
    }

    func nudgeTempo(by delta: Double) {
        tempoBPM = max(40, min(200, (tempoBPM + delta).rounded()))
    }

    /// Changes the transposition (semitones added to the written pitch) and rebuilds the sequence.
    func setTransposition(_ semitones: Int) {
        guard let score = score, semitones != transposition else { return }
        transposition = semitones
        timeline = PlaybackTimeline(score: score, transposition: semitones, preferredBPM: document.preferredBPM)
        rebuildSequence(keepPosition: true)
    }

    // MARK: Export

    /// Renders the music (no count-in) at the current tempo and tuning into an AAC `.m4a` file at `url`.
    func exportAudio(to url: URL) async throws {
        guard let timeline = timeline else { throw PlaybackEngineError.notReady }
        guard let bank = soundBankURL else { throw PlaybackEngineError.soundBankMissing }
        let targetBPM = tempoBPM
        let tuning = a4
        let programNumber = program
        let percussion = usesPercussionBank

        await MainActor.run { self.isExporting = true }
        defer {
            Task { @MainActor in self.isExporting = false }
        }

        let task = Task.detached(priority: .userInitiated) {
            try OfflineAudioRenderer.render(timeline: timeline,
                                            program: programNumber,
                                            usePercussionBank: percussion,
                                            soundBankURL: bank,
                                            targetBPM: targetBPM,
                                            a4: tuning,
                                            to: url)
        }
        try await task.value
    }

    // MARK: Engine setup

    private func configureEngineIfNeeded() {
        guard !engineConfigured else { return }
        engineConfigured = true
        engine.attach(instrumentSampler)
        engine.attach(clickSampler)
        engine.connect(instrumentSampler, to: engine.mainMixerNode, format: nil)
        engine.connect(clickSampler, to: engine.mainMixerNode, format: nil)
    }

    private func loadSoundBank(completion: @escaping () -> Void) {
        guard let url = soundBankURL else {
            errorMessage = PlaybackEngineError.soundBankMissing.localizedDescription
            soundBankLoaded = false
            completion()
            return
        }
        let instrument = instrumentSampler
        let clicks = clickSampler
        let programNumber = program
        let melodicMSB: UInt8 = usesPercussionBank ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
        let percussionMSB: UInt8 = UInt8(kAUSampler_DefaultPercussionBankMSB)
        let lsb: UInt8 = UInt8(kAUSampler_DefaultBankLSB)

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String? = nil
            do {
                try instrument.loadSoundBankInstrument(at: url, program: programNumber, bankMSB: melodicMSB, bankLSB: lsb)
                try clicks.loadSoundBankInstrument(at: url, program: 0, bankMSB: percussionMSB, bankLSB: lsb)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let failure = failure {
                    self.errorMessage = String(localized: "The sounds couldn't be loaded (\(failure)).")
                    self.soundBankLoaded = false
                } else {
                    self.soundBankLoaded = true
                }
                completion()
            }
        }
    }

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
    }

    private func ensureEngineRunning() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: Sequence

    private func rebuildSequence(keepPosition: Bool) {
        guard let timeline = timeline, engineConfigured else { return }
        let resumeBeat: Double = keepPosition ? currentBeat : 0
        let wasPlaying = isPlaying

        stopPolling()
        if let old = sequencer {
            old.stop()
        }
        sequencer = nil
        allNotesOff()
        isPlaying = false
        isCountingIn = false

        let countIn: MIDIFileWriter.CountIn? = countInEnabled ? timeline.countIn(bars: 1) : nil
        let result = MIDIFileWriter.write(timeline: timeline, program: program, baseBPM: baseBPM, countIn: countIn)
        countInBeats = result.countInBeats

        let fresh = AVAudioSequencer(audioEngine: engine)
        do {
            try fresh.load(from: result.data, options: [])
        } catch {
            errorMessage = String(localized: "The music couldn't be prepared for playback (\(error.localizedDescription)).")
            return
        }

        // Track order follows the file: [possibly an empty track for the tempo track], note track, click track (last).
        let tracks: [AVMusicTrack] = fresh.tracks
        for (index, track) in tracks.enumerated() {
            let isClickTrack = result.hasClickTrack && index == tracks.count - 1
            track.destinationAudioUnit = isClickTrack ? clickSampler : instrumentSampler
        }
        fresh.prepareToPlay()
        fresh.rate = Float(tempoBPM / max(baseBPM, 1))
        fresh.currentPositionInBeats = resumeBeat <= 0 ? 0 : countInBeats + resumeBeat
        sequencer = fresh
        currentBeat = resumeBeat

        if wasPlaying {
            play()
        }
    }

    private func applyRate() {
        guard let sequencer = sequencer, baseBPM > 0 else { return }
        sequencer.rate = Float(tempoBPM / baseBPM)
    }

    private func applyTuning() {
        let cents = Float(1200.0 * log2(max(a4, 1) / 440.0))
        instrumentSampler.globalTuning = cents
    }

    /// Keeps the start inside the piece and drags the end along when the start passes it.
    private func clampLoopStart() {
        guard !isClampingLoop else { return }
        isClampingLoop = true
        defer { isClampingLoop = false }
        let maxIndex = max(0, measureCount - 1)
        let start = max(0, min(maxIndex, loopStartMeasure))
        if start != loopStartMeasure { loopStartMeasure = start }
        if loopEndMeasure < start { loopEndMeasure = start }
    }

    /// Keeps the end inside the piece and drags the start along when the end passes it.
    private func clampLoopEnd() {
        guard !isClampingLoop else { return }
        isClampingLoop = true
        defer { isClampingLoop = false }
        let maxIndex = max(0, measureCount - 1)
        let end = max(0, min(maxIndex, loopEndMeasure))
        if end != loopEndMeasure { loopEndMeasure = end }
        if loopStartMeasure > end { loopStartMeasure = end }
    }

    private func allNotesOff() {
        instrumentSampler.sendController(123, withValue: 0, onChannel: MIDIFileWriter.noteChannel)
        clickSampler.sendController(123, withValue: 0, onChannel: MIDIFileWriter.clickChannel)
    }

    // MARK: Polling (position, looping, end of music)

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func updateCurrentBeatFromSequencer() {
        guard let sequencer = sequencer, let timeline = timeline else { return }
        let beat = sequencer.currentPositionInBeats - countInBeats
        currentBeat = max(0, min(timeline.totalBeats, beat))
    }

    private func poll() {
        guard isPlaying, let sequencer = sequencer, let timeline = timeline else { return }
        let position = sequencer.currentPositionInBeats
        let beat = position - countInBeats

        if beat < 0 {
            isCountingIn = true
            currentBeat = 0
            return
        }
        if isCountingIn { isCountingIn = false }

        if loopEnabled {
            let range = timeline.beatRange(fromMeasure: loopStartMeasure, toMeasure: loopEndMeasure)
            if beat >= range.end - 0.001 || beat >= timeline.totalBeats {
                sequencer.currentPositionInBeats = countInBeats + range.start
                allNotesOff()
                currentBeat = range.start
                return
            }
        } else if beat >= timeline.totalBeats + 1.0 || !sequencer.isPlaying {
            sequencer.stop()
            allNotesOff()
            stopPolling()
            isPlaying = false
            sequencer.currentPositionInBeats = 0
            currentBeat = 0
            return
        }

        currentBeat = min(timeline.totalBeats, beat)
    }

    // MARK: Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleConfigurationChange() {
        // The engine stops when the route changes (headphones unplugged etc.). Restart if we were playing.
        if isPlaying {
            pause()
            play()
        }
    }
}

// MARK: - Offline rendering

/// Renders a timeline to an AAC file with its own engine in manual rendering mode, driving the
/// sampler directly from the note events (no sequencer, so timing doesn't depend on the host clock).
enum OfflineAudioRenderer {
    private struct ScheduledNote {
        var frame: Int64
        var isOn: Bool
        var key: UInt8
    }

    static func render(timeline: PlaybackTimeline, program: UInt8, usePercussionBank: Bool, soundBankURL: URL,
                       targetBPM: Double, a4: Double, to url: URL) throws {
        let sampleRate: Double = 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PlaybackEngineError.renderFailed("format")
        }
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)

        let msb: UInt8 = usePercussionBank ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
        try sampler.loadSoundBankInstrument(at: soundBankURL, program: program, bankMSB: msb, bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        sampler.globalTuning = Float(1200.0 * log2(max(a4, 1) / 440.0))

        try engine.start()
        defer { engine.stop() }

        // Schedule note on/off frames at the target tempo.
        var scheduled: [ScheduledNote] = []
        for event in timeline.events {
            let onSeconds = timeline.seconds(atBeat: event.startBeat, targetBPM: targetBPM)
            let offSeconds = timeline.seconds(atBeat: event.endBeat, targetBPM: targetBPM)
            let onFrame = Int64((onSeconds * sampleRate).rounded())
            var offFrame = Int64((offSeconds * sampleRate).rounded())
            if offFrame <= onFrame { offFrame = onFrame + 1 }
            scheduled.append(ScheduledNote(frame: onFrame, isOn: true, key: event.midiSounding))
            scheduled.append(ScheduledNote(frame: offFrame, isOn: false, key: event.midiSounding))
        }
        scheduled.sort { a, b in
            if a.frame != b.frame { return a.frame < b.frame }
            // note-offs before note-ons at the same frame
            return (a.isOn ? 1 : 0) < (b.isOn ? 1 : 0)
        }
        let endSeconds = timeline.seconds(atBeat: timeline.totalBeats, targetBPM: targetBPM) + 1.5
        let totalFrames = Int64((endSeconds * sampleRate).rounded())

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw PlaybackEngineError.renderFailed("buffer")
        }

        var nextIndex = 0
        var stalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            let position: Int64 = engine.manualRenderingSampleTime
            let remaining: Int64 = totalFrames - position
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))

            while nextIndex < scheduled.count && scheduled[nextIndex].frame < position + Int64(frames) {
                let note = scheduled[nextIndex]
                if note.isOn {
                    sampler.startNote(note.key, withVelocity: 96, onChannel: 0)
                } else {
                    sampler.stopNote(note.key, onChannel: 0)
                }
                nextIndex += 1
            }

            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                try file.write(from: buffer)
                stalls = 0
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 100 { throw PlaybackEngineError.renderFailed("render stalled") }
            case .error:
                throw PlaybackEngineError.renderFailed("render error")
            @unknown default:
                throw PlaybackEngineError.renderFailed("unknown render status")
            }
        }
    }
}
