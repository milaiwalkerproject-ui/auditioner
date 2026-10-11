import Foundation
import AVFoundation
import AudioToolbox
import Combine

/// Sine oscillators for the "pure tone" drone. Written on the main thread, read on the render thread;
/// the amplitude is smoothed per sample so starts, stops and retunes never click.
final class SineBank {
    var sampleRate: Double = 44_100
    /// Frequencies to sound (root first, fifth second).
    var frequencies: [Double] = []
    var targetAmplitude: Float = 0

    private var phases: [Double] = [0, 0]
    private var amplitude: Float = 0

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let freqs = frequencies
        let target = targetAmplitude
        let rate = sampleRate > 0 ? sampleRate : 44_100
        let smoothing: Float = 0.0005
        let twoPi = 2 * Double.pi
        for frame in 0..<frameCount {
            amplitude += (target - amplitude) * smoothing
            var value: Float = 0
            var index = 0
            for f in freqs where index < phases.count {
                value += Float(sin(phases[index])) * (index == 0 ? 1.0 : 0.7)
                phases[index] += twoPi * f / rate
                if phases[index] > twoPi { phases[index] -= twoPi }
                index += 1
            }
            let sample = value * amplitude
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let pointer = data.assumingMemoryBound(to: Float.self)
                pointer[frame] = sample
            }
        }
    }
}

/// Plays a sustained note (plus an optional fifth) with the bundled GeneralUser GS sounds or a pure tone.
/// Call everything on the main thread.
final class DroneEngine: ObservableObject {

    // MARK: Published state

    @Published var note: DroneNote = DroneNote(pitchClass: .a, octave: 3) {
        didSet { if isRunning && note != oldValue { retune() } }
    }
    @Published var addFifth: Bool = false {
        didSet { if isRunning && addFifth != oldValue { retune() } }
    }
    @Published var sound: DroneSound = .instrument {
        didSet { if isRunning && sound != oldValue { switchSound() } }
    }
    /// 0…1.
    @Published var volume: Double = 0.7 {
        didSet { applyVolume() }
    }
    /// Tuning of A4 in Hz.
    @Published var a4: Double = 440 {
        didSet { if a4 != oldValue { applyTuning() } }
    }
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isStopping: Bool = false
    @Published private(set) var isLoadingSounds: Bool = false
    @Published private(set) var errorMessage: String?

    /// Which General MIDI program the "instrument sound" uses.
    var instrument: Instrument = .cello

    // MARK: Private state

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var sourceNode: AVAudioSourceNode?
    private let sine = SineBank()
    private var graphBuilt = false
    private var loadedProgram: UInt8?
    private var soundingNotes: [UInt8] = []
    private var fadeTimer: Timer?
    private var fadeLevel: Double = 0
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private let soundBankURL: URL? = Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2")

    static let fadeSeconds: Double = 0.4

    // MARK: Lifecycle

    init() {
        subscribeToSessionEvents()
    }

    deinit {
        fadeTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: Transport

    func start() {
        guard !isRunning, !isStopping, !isLoadingSounds else { return }
        errorMessage = nil
        do {
            try AudioSessionCoordinator.shared.configure(.playback)
            try buildGraphIfNeeded()
        } catch {
            errorMessage = String(localized: "The drone couldn't start (\(error.localizedDescription)).")
            return
        }
        if sound == .instrument && loadedProgram != currentProgram {
            loadSampler { [weak self] in
                self?.startEngineAndSound()
            }
        } else {
            startEngineAndSound()
        }
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        fade(to: 0) { [weak self] in
            guard let self = self else { return }
            self.silence()
            if self.engine.isRunning {
                self.engine.stop()
            }
            self.isRunning = false
            self.isStopping = false
        }
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    /// Frequencies that sound now (root, and the fifth when added) for the current tuning.
    var soundingFrequencies: [Double] {
        currentMidiNotes().map { DroneMath.frequency(midi: $0, a4: a4) }
    }

    // MARK: Graph

    private var currentProgram: UInt8 {
        instrument.gmProgram
    }

    private func currentSampleRate() -> Double {
        let output = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if output > 0 { return output }
        let hardware = AudioSessionCoordinator.shared.hardwareSampleRate
        return hardware > 0 ? hardware : 44_100
    }

    private func buildGraphIfNeeded() throws {
        let rate = currentSampleRate()
        sine.sampleRate = rate
        guard !graphBuilt else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw DroneEngineError.format
        }
        let bank = sine
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            bank.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(sampler)
        engine.attach(node)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        graphBuilt = true
    }

    private func loadSampler(completion: @escaping () -> Void) {
        guard let url = soundBankURL else {
            errorMessage = String(localized: "The app's sound file is missing, so the instrument sound isn't available. Pure tone still works.")
            sound = .pureTone
            completion()
            return
        }
        let program = currentProgram
        let sampler = self.sampler
        isLoadingSounds = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String? = nil
            do {
                try sampler.loadSoundBankInstrument(at: url, program: program,
                                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoadingSounds = false
                if let failure = failure {
                    self.errorMessage = String(localized: "The instrument sound couldn't be loaded (\(failure)). Pure tone still works.")
                    self.sound = .pureTone
                } else {
                    self.loadedProgram = program
                }
                completion()
            }
        }
    }

    private func startEngineAndSound() {
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            errorMessage = String(localized: "The drone couldn't start (\(error.localizedDescription)).")
            return
        }
        isRunning = true
        fadeLevel = 0
        applyVolume()
        beginSounding()
        fade(to: 1, completion: nil)
    }

    // MARK: Sound

    private func currentMidiNotes() -> [Int] {
        var notes = [note.midi]
        if addFifth {
            notes.append(note.midi + 7)
        }
        return notes.map { max(0, min(127, $0)) }
    }

    private func beginSounding() {
        let midiNotes = currentMidiNotes()
        switch sound {
        case .instrument:
            applyTuning()
            sine.targetAmplitude = 0
            soundingNotes = []
            for (index, midi) in midiNotes.enumerated() {
                let key = UInt8(midi)
                sampler.startNote(key, withVelocity: index == 0 ? 100 : 80, onChannel: 0)
                soundingNotes.append(key)
            }
        case .pureTone:
            sine.frequencies = midiNotes.map { DroneMath.frequency(midi: $0, a4: a4) }
            sine.targetAmplitude = 0.3
        }
    }

    private func silence() {
        for key in soundingNotes {
            sampler.stopNote(key, onChannel: 0)
        }
        soundingNotes = []
        sine.targetAmplitude = 0
    }

    private func retune() {
        silence()
        beginSounding()
    }

    private func switchSound() {
        silence()
        if sound == .instrument && loadedProgram != currentProgram {
            loadSampler { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.beginSounding()
            }
        } else {
            beginSounding()
        }
    }

    private func applyTuning() {
        sampler.globalTuning = Float(DroneMath.cents(forA4: a4))
        if isRunning && sound == .pureTone {
            sine.frequencies = currentMidiNotes().map { DroneMath.frequency(midi: $0, a4: a4) }
        }
    }

    private func applyVolume() {
        let clamped = max(0, min(1, volume))
        engine.mainMixerNode.outputVolume = Float(clamped * fadeLevel)
    }

    // MARK: Fades

    private func fade(to target: Double, completion: (() -> Void)?) {
        fadeTimer?.invalidate()
        let steps = max(1, Int(DroneEngine.fadeSeconds * 60))
        let start = fadeLevel
        var step = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            step += 1
            let progress = min(1, Double(step) / Double(steps))
            self.fadeLevel = start + (target - start) * progress
            self.applyVolume()
            if progress >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                completion?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Interruptions

    private func subscribeToSessionEvents() {
        AudioSessionCoordinator.shared.interruptionBegan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hardStop()
            }
            .store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    private func hardStop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        silence()
        if engine.isRunning {
            engine.stop()
        }
        isRunning = false
        isStopping = false
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        hardStop()
        start()
    }
}

enum DroneEngineError: Error {
    case format
}
