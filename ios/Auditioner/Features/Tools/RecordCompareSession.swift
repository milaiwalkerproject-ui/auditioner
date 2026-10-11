import Foundation
import AVFoundation
import Combine

/// Everything a record & compare session needs before it starts.
struct RecordComparePlan {
    /// The reference rendered from beat 0 at the practice tempo and tuning (`PlaybackEngine.exportAudio`).
    var referenceURL: URL
    /// Seconds into that file where the take starts.
    var referenceOffsetSeconds: Double
    var referenceDurationSeconds: Double
    var countInClicks: Int
    var clicksPerBar: Int
    var countInClickSeconds: Double
    var tempoBPM: Double
    var startBeat: Double
    var timeline: PlaybackTimeline
    var takeFileName: String
    var title: String
}

struct RecordedTakeResult {
    var fileName: String
    var durationSeconds: Double
    var plan: RecordComparePlan
}

enum RecordCompareError: Error, LocalizedError {
    case noMicrophone
    case format
    case clock

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return String(localized: "No microphone was found. Check that the microphone is allowed for Auditioner.")
        case .format:
            return String(localized: "The microphone's audio format isn't supported on this device.")
        case .clock:
            return String(localized: "The audio hardware didn't start in time. Please try again.")
        }
    }
}

/// Records the player while the reference plays, in one `AVAudioEngine`.
///
/// How the two stay lined up: the count-in clicks and the reference file are scheduled on player nodes at
/// explicit node times (one shared clock), and the microphone tap writes to the take file only from the
/// node time where the reference starts (plus the route's input + output latency). So take time 0 is the
/// reference at `startBeat`, which is what `PracticeTake.referenceStartBeat` records and what the compare
/// sheet uses to start both together. Call everything on the main thread.
final class RecordCompareSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case countingIn
        case recording
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Seconds since the reference started (0 during the count-in).
    @Published private(set) var elapsedSeconds: Double = 0
    /// Input level as a meter position 0…1.
    @Published private(set) var inputLevel: Double = 0
    /// Beat of the reference that is sounding, for the notation highlight.
    @Published private(set) var referenceBeat: Double? = nil
    @Published private(set) var referenceFinished: Bool = false

    /// Called once when the reference has finished and a few seconds have passed (the view then stops and saves).
    var onAutoStop: (() -> Void)?
    /// Called when a phone call or a route change cut the recording short (the view stops and saves what it has).
    var onInterrupted: (() -> Void)?

    private(set) var plan: RecordComparePlan?

    var isActive: Bool {
        phase == .countingIn || phase == .recording
    }

    var isBusy: Bool {
        phase == .preparing || isActive
    }

    static let autoStopAfterReferenceSeconds: Double = 3
    static let leadInSeconds: Double = 0.25

    // MARK: Private state

    private var engine: AVAudioEngine?
    private var clickPlayer: AVAudioPlayerNode?
    private var referencePlayer: AVAudioPlayerNode?
    private var referenceFile: AVAudioFile?
    private var clickFormat: AVAudioFormat?

    private let writeLock = NSLock()
    private var file: AVAudioFile?
    private var isWriting: Bool = false
    private var writeStartSampleTime: Int64 = 0
    private var framesWritten: Int64 = 0
    private var latestLevel: Double = 0

    private var inputSampleRate: Double = 44_100
    private var nodeSampleRate: Double = 44_100
    private var referenceStartNodeTime: Int64 = 0
    private var pollTimer: Timer?
    private var startAttempts: Int = 0
    private var autoStopSent: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        subscribeToSessionEvents()
    }

    deinit {
        pollTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        teardownEngine()
    }

    // MARK: Phases

    func markPreparing() {
        phase = .preparing
    }

    func fail(_ message: String) {
        teardownEngine()
        phase = .failed(message)
    }

    func clearError() {
        if case .failed = phase {
            phase = .idle
        }
    }

    // MARK: Start

    func start(_ plan: RecordComparePlan) {
        guard !isActive else { return }
        self.plan = plan
        referenceFinished = false
        autoStopSent = false
        elapsedSeconds = 0
        referenceBeat = nil
        inputLevel = 0
        do {
            try AudioSessionCoordinator.shared.configure(.playAndRecord)
            try TakeStore.ensureDirectory()

            let fresh = AVAudioEngine()
            let input = fresh.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecordCompareError.noMicrophone
            }
            guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved else {
                throw RecordCompareError.format
            }
            inputSampleRate = inputFormat.sampleRate

            let reference = try AVAudioFile(forReading: plan.referenceURL)
            let clicks = AVAudioPlayerNode()
            let referenceNode = AVAudioPlayerNode()
            fresh.attach(clicks)
            fresh.attach(referenceNode)
            var outputRate = fresh.outputNode.outputFormat(forBus: 0).sampleRate
            if outputRate <= 0 { outputRate = inputFormat.sampleRate }
            guard let clickFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1) else {
                throw RecordCompareError.format
            }
            fresh.connect(clicks, to: fresh.mainMixerNode, format: clickFormat)
            fresh.connect(referenceNode, to: fresh.mainMixerNode, format: reference.processingFormat)

            // The take file takes the microphone's own format so tap buffers are written as they come.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: Int(inputFormat.channelCount),
                AVEncoderBitRateKey: 128_000,
            ]
            let url = TakeStore.fileURL(fileName: plan.takeFileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

            writeLock.lock()
            file = output
            isWriting = false
            framesWritten = 0
            writeStartSampleTime = 0
            latestLevel = 0
            writeLock.unlock()

            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, when in
                self?.handleInput(buffer, at: when)
            }
            fresh.prepare()
            try fresh.start()

            engine = fresh
            clickPlayer = clicks
            referencePlayer = referenceNode
            referenceFile = reference
            self.clickFormat = clickFormat
            phase = .countingIn
            startAttempts = 0
            scheduleWhenClockReady()
        } catch {
            teardownEngine()
            phase = .failed(error.localizedDescription)
        }
    }

    /// The engine's clock is only readable after its first render; retry for up to a second.
    private func scheduleWhenClockReady() {
        guard let engine = engine, let clicks = clickPlayer, let referenceNode = referencePlayer,
              let plan = plan, let reference = referenceFile, let clickFormat = clickFormat else { return }
        guard let anchor = engine.outputNode.lastRenderTime, anchor.isSampleTimeValid, anchor.sampleRate > 0 else {
            startAttempts += 1
            if startAttempts > 50 {
                teardownEngine()
                phase = .failed(RecordCompareError.clock.localizedDescription)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.scheduleWhenClockReady()
            }
            return
        }

        let rate = anchor.sampleRate
        nodeSampleRate = rate
        let t0: Int64 = anchor.sampleTime + Int64((RecordCompareSession.leadInSeconds * rate).rounded())

        // Count-in: player time 0 of the click node is node time t0.
        let clickFrames = Int64((plan.countInClickSeconds * rate).rounded())
        for k in 0..<max(0, plan.countInClicks) {
            let isDownbeat = plan.clicksPerBar > 0 && k % plan.clicksPerBar == 0
            let kind: TickKind = isDownbeat ? .accent : .beat
            if let buffer = ClickSynth.buffer(sound: .woodblock, kind: kind, format: clickFormat) {
                let when = AVAudioTime(sampleTime: Int64(k) * clickFrames, atRate: rate)
                clicks.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
            }
        }
        let countInFrames: Int64 = Int64(max(0, plan.countInClicks)) * clickFrames
        let referenceStart: Int64 = t0 + countInFrames
        if plan.countInClicks > 0 {
            clicks.play(at: AVAudioTime(sampleTime: t0, atRate: rate))
        }

        // Reference from the start beat, at node time referenceStart.
        let referenceRate = reference.processingFormat.sampleRate
        let offsetFrames = AVAudioFramePosition((plan.referenceOffsetSeconds * referenceRate).rounded())
        if offsetFrames < reference.length {
            referenceNode.scheduleSegment(reference, startingFrame: offsetFrames,
                                          frameCount: AVAudioFrameCount(reference.length - offsetFrames),
                                          at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.referenceFinished = true }
            }
            referenceNode.play(at: AVAudioTime(sampleTime: referenceStart, atRate: rate))
        } else {
            referenceFinished = true
        }
        referenceStartNodeTime = referenceStart

        // The speaker plays the first note outputLatency later, and the tap receives it inputLatency after that.
        let latencyFrames = Int64((AudioSessionCoordinator.shared.roundTripLatency * rate).rounded())
        writeLock.lock()
        writeStartSampleTime = referenceStart + latencyFrames
        isWriting = true
        writeLock.unlock()

        startPolling()
    }

    // MARK: Input tap (audio queue)

    private func handleInput(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let level = PCMBufferTools.rmsLevel(of: buffer)
        writeLock.lock()
        defer { writeLock.unlock() }
        latestLevel = level
        guard isWriting, let file = file else { return }
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }
        let start: Int64 = when.isSampleTimeValid ? when.sampleTime : writeStartSampleTime
        let end: Int64 = start + frames
        if end <= writeStartSampleTime { return }
        if start >= writeStartSampleTime {
            if (try? file.write(from: buffer)) != nil {
                framesWritten += frames
            }
            return
        }
        let skip = Int(writeStartSampleTime - start)
        if let trimmed = PCMBufferTools.droppingFirst(skip, of: buffer) {
            if (try? file.write(from: trimmed)) != nil {
                framesWritten += Int64(trimmed.frameLength)
            }
        } else if (try? file.write(from: buffer)) != nil {
            framesWritten += frames
        }
    }

    // MARK: Stop

    /// Stops everything. Returns the take when something was recorded; otherwise deletes the file.
    func stop() -> RecordedTakeResult? {
        stopPolling()
        let wasActive = isActive
        guard let plan = plan else {
            teardownEngine()
            phase = .idle
            return nil
        }
        let frames = finishWriting()
        teardownEngine()
        phase = .idle
        referenceBeat = nil
        inputLevel = 0
        self.plan = nil
        let url = TakeStore.fileURL(fileName: plan.takeFileName)
        guard wasActive, frames > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let duration = TakeStore.durationSeconds(of: url) ?? (Double(frames) / inputSampleRate)
        return RecordedTakeResult(fileName: plan.takeFileName, durationSeconds: duration, plan: plan)
    }

    /// Stops and throws the recording away.
    func cancel() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: TakeStore.fileURL(fileName: result.fileName))
        }
    }

    private func finishWriting() -> Int64 {
        engine?.inputNode.removeTap(onBus: 0)
        writeLock.lock()
        isWriting = false
        let frames = framesWritten
        file = nil
        writeLock.unlock()
        return frames
    }

    private func teardownEngine() {
        clickPlayer?.stop()
        referencePlayer?.stop()
        if let engine = engine, engine.isRunning {
            engine.stop()
        }
        writeLock.lock()
        isWriting = false
        file = nil
        writeLock.unlock()
        engine = nil
        clickPlayer = nil
        referencePlayer = nil
        referenceFile = nil
        clickFormat = nil
    }

    // MARK: Polling (position, level, auto-stop)

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

    private func poll() {
        guard isActive, let engine = engine, let plan = plan,
              let now = engine.outputNode.lastRenderTime, now.isSampleTimeValid else { return }
        writeLock.lock()
        let level = latestLevel
        writeLock.unlock()
        inputLevel = PCMBufferTools.meterPosition(linearLevel: level)

        let elapsed = Double(now.sampleTime - referenceStartNodeTime) / max(1, nodeSampleRate)
        if elapsed < 0 {
            if phase != .countingIn { phase = .countingIn }
            elapsedSeconds = 0
            referenceBeat = nil
            return
        }
        if phase == .countingIn { phase = .recording }
        elapsedSeconds = elapsed
        referenceBeat = plan.timeline.beat(atSeconds: plan.referenceOffsetSeconds + elapsed, targetBPM: plan.tempoBPM)

        let remaining = plan.referenceDurationSeconds - plan.referenceOffsetSeconds
        if !autoStopSent, elapsed > remaining + RecordCompareSession.autoStopAfterReferenceSeconds {
            autoStopSent = true
            onAutoStop?()
        }
    }

    // MARK: Interruptions

    private func subscribeToSessionEvents() {
        AudioSessionCoordinator.shared.interruptionBegan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.isActive else { return }
                self.onInterrupted?()
            }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.isActive, let engine = self.engine,
                  let changed = note.object as? AVAudioEngine, changed === engine else { return }
            self.onInterrupted?()
        })
    }
}

// MARK: - Timeline helper

extension PlaybackTimeline {
    /// Inverse of `seconds(atBeat:targetBPM:)`: the beat reached after `seconds` of music that starts at `targetBPM`.
    func beat(atSeconds seconds: Double, targetBPM: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let map = tempoMap(baseBPM: targetBPM)
        var time: Double = 0
        var lastBeat: Double = 0
        var bpm: Double = map.first?.bpm ?? targetBPM
        for change in map.dropFirst() {
            if change.beat > lastBeat {
                let segmentSeconds = (change.beat - lastBeat) * 60.0 / max(bpm, 1)
                if time + segmentSeconds >= seconds {
                    return min(totalBeats, lastBeat + (seconds - time) * max(bpm, 1) / 60.0)
                }
                time += segmentSeconds
                lastBeat = change.beat
            }
            bpm = change.bpm
        }
        return min(totalBeats, lastBeat + (seconds - time) * max(bpm, 1) / 60.0)
    }
}
