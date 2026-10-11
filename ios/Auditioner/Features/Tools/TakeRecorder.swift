import Foundation
import AVFoundation
import Combine

enum TakeRecorderError: Error, LocalizedError {
    case couldNotStart
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return String(localized: "Recording couldn't start. Check that the microphone is allowed for Auditioner.")
        case .alreadyRecording:
            return String(localized: "A recording is already running.")
        }
    }
}

/// Records the player to an AAC `.m4a` file in Documents/Takes/ with `AVAudioRecorder`,
/// publishing a live input level and the elapsed time. Call everything on the main thread.
final class TakeRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: Double = 0
    /// Input level as a meter position 0…1.
    @Published private(set) var level: Double = 0
    @Published private(set) var errorMessage: String?

    private(set) var fileURL: URL?
    private(set) var fileName: String?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    override init() {
        super.init()
        subscribeToSessionEvents()
    }

    deinit {
        meterTimer?.invalidate()
        recorder?.stop()
    }

    // MARK: Transport

    /// Starts a new file named `fileName` in Documents/Takes/.
    func start(fileName: String) throws {
        guard !isRecording else { throw TakeRecorderError.alreadyRecording }
        errorMessage = nil
        try AudioSessionCoordinator.shared.configure(.playAndRecord)
        try TakeStore.ensureDirectory()
        let url = TakeStore.fileURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let fresh = try AVAudioRecorder(url: url, settings: TakeRecorder.settings)
        fresh.delegate = self
        fresh.isMeteringEnabled = true
        guard fresh.prepareToRecord(), fresh.record() else {
            throw TakeRecorderError.couldNotStart
        }
        recorder = fresh
        fileURL = url
        self.fileName = fileName
        isRecording = true
        elapsedSeconds = 0
        level = 0
        startMetering()
    }

    /// Seconds recorded so far (also valid while paused by an interruption).
    var currentTime: Double {
        recorder?.currentTime ?? elapsedSeconds
    }

    /// Stops and returns the file and its measured length, or `nil` when nothing was recording.
    @discardableResult
    func stop() -> (url: URL, fileName: String, durationSeconds: Double)? {
        guard let active = recorder, let url = fileURL, let name = fileName else { return nil }
        let timed = active.currentTime
        active.stop()
        stopMetering()
        recorder = nil
        isRecording = false
        level = 0
        let duration = TakeStore.durationSeconds(of: url) ?? timed
        elapsedSeconds = duration
        return (url, name, duration)
    }

    /// Stops and throws the file away.
    func cancel() {
        guard let active = recorder else { return }
        active.stop()
        active.deleteRecording()
        stopMetering()
        recorder = nil
        isRecording = false
        level = 0
        elapsedSeconds = 0
        fileURL = nil
        fileName = nil
    }

    // MARK: Metering

    private func startMetering() {
        stopMetering()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func poll() {
        guard let active = recorder else { return }
        active.updateMeters()
        let decibels = Double(active.averagePower(forChannel: 0))
        level = PCMBufferTools.meterPosition(decibels: decibels)
        elapsedSeconds = active.currentTime
    }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        errorMessage = String(localized: "Recording stopped because of an error (\(error?.localizedDescription ?? "unknown")).")
        _ = stop()
    }

    // MARK: Interruptions

    private func subscribeToSessionEvents() {
        let coordinator = AudioSessionCoordinator.shared
        coordinator.interruptionBegan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorder?.pause()
            }
            .store(in: &cancellables)
        coordinator.interruptionEnded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldResume in
                guard let self = self, self.isRecording, shouldResume, let active = self.recorder else { return }
                if !active.isRecording {
                    _ = active.record()
                }
            }
            .store(in: &cancellables)
    }
}
