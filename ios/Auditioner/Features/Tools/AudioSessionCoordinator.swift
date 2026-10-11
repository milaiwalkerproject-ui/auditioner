import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// What a practice tool needs from the audio hardware.
enum AudioSessionMode: Equatable {
    /// Reference audio, metronome, drone, playing back takes.
    case playback
    /// Recording the player, with or without playback at the same time.
    case playAndRecord
}

enum MicPermissionState: Equatable {
    case undetermined
    case granted
    case denied
}

/// The one place the practice tools talk to `AVAudioSession`.
///
/// Configures the category for playback or recording, keeps the microphone permission state,
/// and republishes interruptions and route changes so each engine can stop or restart itself.
/// Everything is called on the main thread.
final class AudioSessionCoordinator: ObservableObject {
    static let shared = AudioSessionCoordinator()

    @Published private(set) var micPermission: MicPermissionState = .undetermined
    @Published private(set) var isHeadphonesConnected: Bool = false
    @Published private(set) var currentMode: AudioSessionMode? = nil

    /// Fired when the system interrupts audio (a phone call, another app).
    let interruptionBegan = PassthroughSubject<Void, Never>()
    /// Fired when an interruption ends; `true` when the system says playback may resume.
    let interruptionEnded = PassthroughSubject<Bool, Never>()
    /// Fired when the output or input route changes (headphones plugged in or out etc.).
    let routeChanged = PassthroughSubject<AVAudioSession.RouteChangeReason, Never>()

    private var observers: [NSObjectProtocol] = []

    init() {
        micPermission = AudioSessionCoordinator.readMicPermission()
        registerObservers()
        refreshRoute()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Session

    /// Sets the category for `mode` and activates the session.
    func configure(_ mode: AudioSessionMode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .playback:
            try session.setCategory(.playback, mode: .default, options: [])
        case .playAndRecord:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        try session.setActive(true, options: [])
        currentMode = mode
        refreshRoute()
    }

    /// Lets other apps' audio come back. Call when the last tool stops.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        currentMode = nil
    }

    /// Hardware sample rate of the current route (0 when unknown).
    var hardwareSampleRate: Double {
        AVAudioSession.sharedInstance().sampleRate
    }

    /// Input plus output latency of the current route, in seconds.
    var roundTripLatency: Double {
        let session = AVAudioSession.sharedInstance()
        return max(0, session.inputLatency) + max(0, session.outputLatency)
    }

    // MARK: Microphone permission

    func refreshMicPermission() {
        micPermission = AudioSessionCoordinator.readMicPermission()
    }

    /// Asks for the microphone the first time; afterwards answers straight away.
    func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        switch micPermission {
        case .granted:
            completion(true)
            return
        case .denied:
            completion(false)
            return
        case .undetermined:
            break
        }
        // The label is spelled out so the completion-handler overload is picked, not the async one.
        AVAudioApplication.requestRecordPermission(completionHandler: { [weak self] (granted: Bool) in
            DispatchQueue.main.async {
                self?.micPermission = granted ? .granted : .denied
                completion(granted)
            }
        })
    }

    static func readMicPermission() -> MicPermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    /// The Settings page for this app, where the microphone switch lives.
    static var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    // MARK: Route

    static func routeHasHeadphones(_ route: AVAudioSessionRouteDescription) -> Bool {
        for output in route.outputs {
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func refreshRoute() {
        isHeadphonesConnected = AudioSessionCoordinator.routeHasHeadphones(AVAudioSession.sharedInstance().currentRoute)
    }

    // MARK: Notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            interruptionBegan.send(())
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            interruptionEnded.send(options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        refreshRoute()
        let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) ?? .unknown
        routeChanged.send(reason)
    }
}

// MARK: - Microphone permission views

/// Shows `content` once the microphone is allowed; otherwise asks for it, or explains how to turn it on.
struct MicrophoneGate<Content: View>: View {
    @ObservedObject private var coordinator: AudioSessionCoordinator = AudioSessionCoordinator.shared
    let purpose: String
    let content: () -> Content

    init(purpose: String, @ViewBuilder content: @escaping () -> Content) {
        self.purpose = purpose
        self.content = content
    }

    var body: some View {
        switch coordinator.micPermission {
        case .granted:
            content()
        case .undetermined:
            MicPermissionRequestView(purpose: purpose)
        case .denied:
            MicPermissionDeniedView()
        }
    }
}

struct MicPermissionRequestView: View {
    let purpose: String

    var body: some View {
        ContentUnavailableView {
            Label("Microphone needed", systemImage: "mic")
        } description: {
            Text(purpose)
        } actions: {
            Button {
                AudioSessionCoordinator.shared.requestMicPermission { _ in }
            } label: {
                Text("Allow the microphone")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Friendly denied state with a way into Settings.
struct MicPermissionDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Microphone is off", systemImage: "mic.slash")
        } description: {
            Text("Recording needs the microphone. Turn it on for Auditioner in Settings, then come back here.")
        } actions: {
            Button {
                if let url = AudioSessionCoordinator.settingsURL {
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear {
            AudioSessionCoordinator.shared.refreshMicPermission()
        }
    }
}
