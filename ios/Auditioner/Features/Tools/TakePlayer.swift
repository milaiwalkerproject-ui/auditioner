import Foundation
import AVFoundation
import Combine

/// What you hear in the compare sheet.
enum CompareMix: String, CaseIterable, Identifiable {
    case you
    case reference
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .you: return String(localized: "You")
        case .reference: return String(localized: "Reference")
        case .both: return String(localized: "Both")
        }
    }
}

/// Plays a take, and optionally the reference audio alongside it, with a speed control that keeps the pitch
/// (`AVAudioUnitTimePitch`, 0.5×–1.0×).
///
/// Sync: both files go through their own player node in one engine, and both nodes are started with the
/// same `play(at:)` node time, so "Both" starts sample-aligned; the two time-pitch units run at the same rate,
/// so they stay aligned when slowed down. Call everything on the main thread.
final class TakePlayer: ObservableObject {

    @Published private(set) var isPlaying: Bool = false
    /// Position in the take, seconds.
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    /// 0.5…1.0.
    @Published var rate: Double = 1 {
        didSet { applyRate() }
    }
    @Published var mix: CompareMix = .you {
        didSet { applyMix() }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasReference: Bool = false
    @Published private(set) var isLoaded: Bool = false

    static let rateChoices: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    /// "0.7×" / "1×" for the speed picker.
    static func rateLabel(_ rate: Double) -> String {
        if rate >= 0.999 { return "1×" }
        return String(format: "%.1f×", rate)
    }

    private let engine = AVAudioEngine()
    private let takeNode = AVAudioPlayerNode()
    private let referenceNode = AVAudioPlayerNode()
    private let takePitch = AVAudioUnitTimePitch()
    private let referencePitch = AVAudioUnitTimePitch()
    private var takeFile: AVAudioFile?
    private var referenceFile: AVAudioFile?
    private var referenceOffsetSeconds: Double = 0
    private var segmentStartSeconds: Double = 0
    private var nodesAttached = false
    private var pollTimer: Timer?
    private var generation: Int = 0
    private var pendingSegments: Int = 0
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
        takeNode.stop()
        referenceNode.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: Loading

    /// Loads the take and, for record & compare, the reference file. Take time 0 lines up with
    /// `referenceOffsetSeconds` into the reference.
    func load(takeURL: URL, referenceURL: URL? = nil, referenceOffsetSeconds: Double = 0) {
        stop()
        errorMessage = nil
        isLoaded = false
        do {
            let take = try AVAudioFile(forReading: takeURL)
            var reference: AVAudioFile? = nil
            if let url = referenceURL {
                reference = try? AVAudioFile(forReading: url)
            }
            if !nodesAttached {
                engine.attach(takeNode)
                engine.attach(takePitch)
                engine.attach(referenceNode)
                engine.attach(referencePitch)
                nodesAttached = true
            }
            if engine.isRunning {
                engine.stop()
            }
            engine.disconnectNodeOutput(takeNode)
            engine.disconnectNodeOutput(takePitch)
            engine.disconnectNodeOutput(referenceNode)
            engine.disconnectNodeOutput(referencePitch)
            engine.connect(takeNode, to: takePitch, format: take.processingFormat)
            engine.connect(takePitch, to: engine.mainMixerNode, format: take.processingFormat)
            if let reference = reference {
                engine.connect(referenceNode, to: referencePitch, format: reference.processingFormat)
                engine.connect(referencePitch, to: engine.mainMixerNode, format: reference.processingFormat)
            }
            takeFile = take
            referenceFile = reference
            hasReference = reference != nil
            self.referenceOffsetSeconds = max(0, referenceOffsetSeconds)
            let rate = take.processingFormat.sampleRate
            durationSeconds = rate > 0 ? Double(take.length) / rate : 0
            currentSeconds = 0
            segmentStartSeconds = 0
            isLoaded = true
            applyRate()
            applyMix()
        } catch {
            takeFile = nil
            referenceFile = nil
            hasReference = false
            errorMessage = String(localized: "This recording couldn't be opened (\(error.localizedDescription)).")
        }
    }

    // MARK: Transport

    func play(from seconds: Double? = nil) {
        guard let take = takeFile else { return }
        let startSeconds = max(0, min(durationSeconds, seconds ?? currentSeconds))
        stopNodes()
        do {
            try AudioSessionCoordinator.shared.configure(.playback)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            errorMessage = String(localized: "Playback couldn't start (\(error.localizedDescription)).")
            return
        }

        let takeRate = take.processingFormat.sampleRate
        let takeStart = AVAudioFramePosition((startSeconds * takeRate).rounded())
        guard takeStart < take.length else {
            currentSeconds = durationSeconds
            isPlaying = false
            return
        }

        generation += 1
        let gen = generation
        pendingSegments = 1
        takeNode.scheduleSegment(take, startingFrame: takeStart, frameCount: AVAudioFrameCount(take.length - takeStart),
                                 at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(generation: gen) }
        }

        var referenceScheduled = false
        if let reference = referenceFile {
            let refRate = reference.processingFormat.sampleRate
            let refStart = AVAudioFramePosition(((referenceOffsetSeconds + startSeconds) * refRate).rounded())
            if refStart < reference.length {
                referenceNode.scheduleSegment(reference, startingFrame: refStart, frameCount: AVAudioFrameCount(reference.length - refStart),
                                              at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { self?.segmentFinished(generation: gen) }
                }
                pendingSegments += 1
                referenceScheduled = true
            }
        }

        // One start time for both nodes keeps them sample-aligned.
        var startTime: AVAudioTime? = nil
        if let now = engine.outputNode.lastRenderTime, now.isSampleTimeValid, now.sampleRate > 0 {
            let lead = Int64((0.05 * now.sampleRate).rounded())
            startTime = AVAudioTime(sampleTime: now.sampleTime + lead, atRate: now.sampleRate)
        }
        takeNode.play(at: startTime)
        if referenceScheduled {
            referenceNode.play(at: startTime)
        }
        segmentStartSeconds = startSeconds
        currentSeconds = startSeconds
        isPlaying = true
        startPolling()
    }

    func pause() {
        stopNodes()
        stopPolling()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            if currentSeconds >= durationSeconds - 0.05 {
                play(from: 0)
            } else {
                play()
            }
        }
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        stopNodes()
        currentSeconds = max(0, min(durationSeconds, seconds))
        if wasPlaying {
            play(from: currentSeconds)
        }
    }

    /// Stops and releases the hardware; the position goes back to the start.
    func stop() {
        stopNodes()
        stopPolling()
        isPlaying = false
        currentSeconds = 0
        segmentStartSeconds = 0
        if engine.isRunning {
            engine.stop()
        }
    }

    private func stopNodes() {
        generation += 1
        pendingSegments = 0
        takeNode.stop()
        referenceNode.stop()
    }

    private func segmentFinished(generation gen: Int) {
        guard gen == generation else { return }
        pendingSegments -= 1
        guard pendingSegments <= 0 else { return }
        takeNode.stop()
        referenceNode.stop()
        stopPolling()
        isPlaying = false
        currentSeconds = durationSeconds
    }

    // MARK: Mix and rate

    private func applyMix() {
        takeNode.volume = (mix == .reference) ? 0 : 1
        referenceNode.volume = (hasReference && mix != .you) ? 0.9 : 0
    }

    private func applyRate() {
        let clamped = Float(max(0.5, min(1.0, rate)))
        takePitch.rate = clamped
        referencePitch.rate = clamped
    }

    // MARK: Position polling

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
        guard isPlaying,
              let nodeTime = takeNode.lastRenderTime,
              let playerTime = takeNode.playerTime(forNodeTime: nodeTime),
              playerTime.isSampleTimeValid, playerTime.sampleRate > 0 else { return }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentSeconds = max(segmentStartSeconds, min(durationSeconds, segmentStartSeconds + played))
    }

    // MARK: Interruptions

    private func subscribeToSessionEvents() {
        AudioSessionCoordinator.shared.interruptionBegan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pause()
            }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    private func handleConfigurationChange() {
        guard isPlaying else { return }
        let position = currentSeconds
        pause()
        play(from: position)
    }
}
