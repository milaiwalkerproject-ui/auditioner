import Foundation
import Combine

/// "Play from here" in the editor: plays a couple of bars of the edited score with the normal
/// reference-audio engine, then stops. A fresh `PlaybackEngine` is built whenever the music changed.
/// Call everything on the main thread (like `PlaybackEngine`).
final class EditorPreviewPlayer: ObservableObject {
    /// Bars played from the selected bar.
    static let previewBars = 2

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPreparing: Bool = false
    /// Beat to highlight in the notation while the preview plays.
    @Published private(set) var highlightBeat: Double?
    @Published var errorMessage: String?

    private var engine: PlaybackEngine?
    private var engineXML: String?
    private var cancellables: Set<AnyCancellable> = []
    private var stopAtBeat: Double = 0
    private var pendingStartMeasure: Int?

    /// Plays `EditorPreviewPlayer.previewBars` bars starting at measure `measureIndex` of `document`.
    func play(document: ScoreDocument, fromMeasure measureIndex: Int, a4: Double) {
        errorMessage = nil
        if let engine = engine, engineXML == document.musicXML {
            engine.a4 = a4
            if engine.isReady {
                start(engine: engine, measureIndex: measureIndex)
            } else {
                pendingStartMeasure = measureIndex
            }
            return
        }

        tearDown()
        let fresh = PlaybackEngine(document: document)
        fresh.a4 = a4
        engine = fresh
        engineXML = document.musicXML
        pendingStartMeasure = measureIndex
        isPreparing = true
        observe(fresh)
        fresh.prepare()
        if let message = fresh.errorMessage {
            errorMessage = message
            isPreparing = false
            pendingStartMeasure = nil
        }
    }

    func stop() {
        pendingStartMeasure = nil
        engine?.pause()
        isPlaying = false
        isPreparing = false
        highlightBeat = nil
    }

    /// Releases the audio hardware (call when the editor goes away).
    func shutdown() {
        pendingStartMeasure = nil
        tearDown()
        isPlaying = false
        isPreparing = false
        highlightBeat = nil
    }

    // MARK: Private

    private func tearDown() {
        cancellables.removeAll()
        engine?.shutdown()
        engine = nil
        engineXML = nil
    }

    private func observe(_ engine: PlaybackEngine) {
        engine.$isReady
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] ready in
                guard let self = self, let engine = engine, ready else { return }
                self.isPreparing = false
                if let measure = self.pendingStartMeasure {
                    self.pendingStartMeasure = nil
                    self.start(engine: engine, measureIndex: measure)
                }
            }
            .store(in: &cancellables)

        engine.$currentBeat
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] beat in
                guard let self = self, let engine = engine else { return }
                guard self.isPlaying else { return }
                if beat >= self.stopAtBeat - 0.01 {
                    engine.pause()
                    self.isPlaying = false
                    self.highlightBeat = nil
                } else {
                    self.highlightBeat = beat
                }
            }
            .store(in: &cancellables)

        engine.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self = self else { return }
                if !playing && self.isPlaying {
                    self.isPlaying = false
                    self.highlightBeat = nil
                }
            }
            .store(in: &cancellables)

        engine.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self = self, let message = message else { return }
                self.errorMessage = message
                self.isPreparing = false
                self.isPlaying = false
                self.highlightBeat = nil
            }
            .store(in: &cancellables)
    }

    private func start(engine: PlaybackEngine, measureIndex: Int) {
        guard let timeline = engine.timeline else {
            errorMessage = PlaybackEngineError.notReady.localizedDescription
            return
        }
        let lastIndex = max(0, timeline.measureCount - 1)
        let from = max(0, min(lastIndex, measureIndex))
        let to = min(lastIndex, from + EditorPreviewPlayer.previewBars - 1)
        let range = timeline.beatRange(fromMeasure: from, toMeasure: to)
        stopAtBeat = range.end
        engine.loopEnabled = false
        engine.countInEnabled = false
        highlightBeat = range.start
        isPlaying = true
        engine.play(fromBeat: range.start)
        if !engine.isPlaying {
            // play() failed; its error message arrives through the sink.
            isPlaying = false
            highlightBeat = nil
        }
    }
}
