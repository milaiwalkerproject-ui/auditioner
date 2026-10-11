import Foundation
import AVFoundation
import Combine

/// Sample-accurate metronome.
///
/// An `AVAudioPlayerNode` plays pre-rendered click buffers scheduled at exact sample times
/// (look-ahead scheduler: ticks are queued one second ahead, computed from the tick index so
/// nothing drifts). A timer only tops up the queue; it never fires a click itself. The visual
/// beat is published from the player's "data rendered" callbacks. Call everything on the main thread.
final class MetronomeEngine: ObservableObject {

    // MARK: Published state

    @Published var settings: MetronomeSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var isRunning: Bool = false
    /// 1-based beat of the bar that is sounding (0 while stopped).
    @Published private(set) var currentBeat: Int = 0
    @Published private(set) var currentBeatIsAccent: Bool = false
    /// Goes up by one on every beat (drives the flash animation).
    @Published private(set) var beatCounter: Int = 0
    @Published private(set) var errorMessage: String?

    static let lookaheadSeconds: Double = 1.0
    static let firstTickDelaySeconds: Double = 0.1
    static let safetyTimerSeconds: Double = 0.25

    // MARK: Private state

    private struct ScheduleState {
        var generation: Int
        var settings: MetronomeSettings
        var sampleRate: Double
        /// Player-timeline frame of tick 0.
        var anchorFrame: Int64
        var nextTick: Int
        /// 0-based beat of the bar that tick 0 falls on.
        var startBeat: Int
        var buffers: [TickKind: AVAudioPCMBuffer]
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let schedulerQueue = DispatchQueue(label: "auditioner.metronome.scheduler", qos: .userInteractive)
    private let stateLock = NSLock()
    private var scheduleState: ScheduleState?
    private var generation: Int = 0
    private var safetyTimer: DispatchSourceTimer?
    private var playerAttached = false
    private var connectedSampleRate: Double = 0
    private var tapTimes: [TimeInterval] = []
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    init(settings: MetronomeSettings = MetronomeSettings()) {
        self.settings = settings
        subscribeToSessionEvents()
    }

    deinit {
        stopInternal()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Transport

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            try AudioSessionCoordinator.shared.configure(.playback)
            try connectPlayer()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            errorMessage = String(localized: "The metronome couldn't start (\(error.localizedDescription)).")
            return
        }
        isRunning = true
        currentBeat = 0
        restartSchedule(startBeat: 0)
    }

    func stop() {
        guard isRunning else { return }
        stopInternal()
        isRunning = false
        currentBeat = 0
        currentBeatIsAccent = false
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    /// One tap of "tap tempo". Sets the BPM from the average of the last taps.
    func tap(at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        tapTimes = MetronomeMath.trimmedTaps(tapTimes, adding: time)
        if let bpm = MetronomeMath.tapTempo(tapTimes: tapTimes) {
            settings.bpm = bpm
        }
    }

    func setBPM(_ bpm: Double) {
        let clamped = MetronomeMath.clampBPM(bpm.rounded())
        if clamped != settings.bpm {
            settings.bpm = clamped
        }
    }

    func nudgeBPM(by delta: Double) {
        setBPM(settings.bpm + delta)
    }

    // MARK: Engine

    private func currentSampleRate() -> Double {
        let output = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if output > 0 { return output }
        let hardware = AudioSessionCoordinator.shared.hardwareSampleRate
        return hardware > 0 ? hardware : 44_100
    }

    private func connectPlayer() throws {
        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        let rate = currentSampleRate()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw MetronomeEngineError.format
        }
        if rate != connectedSampleRate {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedSampleRate = rate
        }
    }

    private func stopInternal() {
        stateLock.lock()
        generation += 1
        scheduleState = nil
        stateLock.unlock()
        safetyTimer?.cancel()
        safetyTimer = nil
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
    }

    // MARK: Scheduling

    /// Flushes the queue and starts a fresh schedule whose first tick lands on `startBeat` of the bar.
    private func restartSchedule(startBeat: Int) {
        guard engine.isRunning, connectedSampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: connectedSampleRate, channels: 1) else {
            errorMessage = String(localized: "The metronome couldn't start.")
            return
        }
        var buffers: [TickKind: AVAudioPCMBuffer] = [:]
        for kind in [TickKind.accent, TickKind.beat, TickKind.subdivision] {
            if let buffer = ClickSynth.buffer(sound: settings.sound, kind: kind, format: format) {
                buffers[kind] = buffer
            }
        }
        let anchor = Int64((MetronomeEngine.firstTickDelaySeconds * connectedSampleRate).rounded())

        stateLock.lock()
        generation += 1
        scheduleState = ScheduleState(generation: generation,
                                      settings: settings,
                                      sampleRate: connectedSampleRate,
                                      anchorFrame: anchor,
                                      nextTick: 0,
                                      startBeat: startBeat,
                                      buffers: buffers)
        stateLock.unlock()

        player.stop()
        player.play()
        schedulerQueue.async { [weak self] in
            self?.scheduleAhead()
        }
        startSafetyTimer()
    }

    /// Current position in the player's own timeline (frames since `play()`), or `nil` before the first render.
    private func currentPlayerSampleTime() -> Int64? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid else { return nil }
        return playerTime.sampleTime
    }

    /// Queues every tick that falls within the look-ahead window. Runs on `schedulerQueue`.
    private func scheduleAhead() {
        stateLock.lock()
        guard var state = scheduleState, state.generation == generation else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let now: Int64 = currentPlayerSampleTime() ?? 0
        let horizon: Int64 = now + Int64((MetronomeEngine.lookaheadSeconds * state.sampleRate).rounded())
        var scheduled = 0
        while scheduled < 512 {
            let frame: Int64 = state.anchorFrame + MetronomeMath.frame(ofTick: state.nextTick,
                                                                        bpm: state.settings.bpm,
                                                                        sampleRate: state.sampleRate,
                                                                        subdivision: state.settings.subdivision)
            if frame >= horizon { break }
            let tick = state.nextTick
            let kind = MetronomeMath.tickKind(tick: tick,
                                              beatsPerBar: state.settings.beatsPerBar,
                                              subdivision: state.settings.subdivision,
                                              accentFirstBeat: state.settings.accentFirstBeat,
                                              startBeat: state.startBeat)
            let beat = MetronomeMath.beatInBar(tick: tick,
                                               beatsPerBar: state.settings.beatsPerBar,
                                               subdivision: state.settings.subdivision,
                                               startBeat: state.startBeat)
            guard let buffer = state.buffers[kind] else { break }
            let gen = state.generation
            let when = AVAudioTime(sampleTime: frame, atRate: state.sampleRate)
            player.scheduleBuffer(buffer, at: when, options: [], completionCallbackType: .dataRendered) { [weak self] _ in
                self?.tickRendered(generation: gen, kind: kind, beat: beat)
            }
            state.nextTick += 1
            scheduled += 1
        }

        stateLock.lock()
        if let current = scheduleState, current.generation == state.generation {
            scheduleState = state
        }
        stateLock.unlock()
    }

    /// Called by the player when a click's samples have been rendered (within a few ms of the sound).
    private func tickRendered(generation gen: Int, kind: TickKind, beat: Int) {
        stateLock.lock()
        let live = (gen == generation)
        stateLock.unlock()
        guard live else { return }
        if kind != .subdivision {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.currentBeat = beat + 1
                self.currentBeatIsAccent = (kind == .accent)
                self.beatCounter &+= 1
            }
        }
        schedulerQueue.async { [weak self] in
            self?.scheduleAhead()
        }
    }

    private func startSafetyTimer() {
        safetyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: schedulerQueue)
        let interval = MetronomeEngine.safetyTimerSeconds
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.scheduleAhead()
        }
        timer.resume()
        safetyTimer = timer
    }

    // MARK: Changes

    private func settingsDidChange(from old: MetronomeSettings) {
        guard isRunning, old != settings else { return }
        // Carry on from the next beat so the bar count doesn't jump.
        let nextBeat = currentBeat % max(1, settings.beatsPerBar)
        restartSchedule(startBeat: nextBeat)
    }

    private func subscribeToSessionEvents() {
        let coordinator = AudioSessionCoordinator.shared
        coordinator.interruptionBegan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.stop()
            }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    /// The engine stops when the route changes (headphones in or out). Start again if we were running.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        let beat = currentBeat
        stopInternal()
        isRunning = false
        connectedSampleRate = 0
        start()
        if isRunning, beat > 0 {
            restartSchedule(startBeat: beat % max(1, settings.beatsPerBar))
        }
    }
}

enum MetronomeEngineError: Error {
    case format
}
