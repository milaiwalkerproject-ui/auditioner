import SwiftUI
import SwiftData
import Combine

/// State machine of one mock audition: prep countdown → play → next, with an optional continuous recording.
final class MockAuditionRunModel: ObservableObject {
    enum Phase: Equatable {
        case notStarted
        case prep(remaining: Int)
        case playing
        case finished
    }

    @Published private(set) var phase: Phase = .notStarted
    @Published private(set) var index: Int = 0
    @Published private(set) var items: [MockAuditionItem]
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var recordingNotice: String?

    let config: MockAuditionConfig
    let recorder = TakeRecorder()

    private var timer: Timer?
    private var startDate: Date?
    private var prepEndDate: Date?

    init(config: MockAuditionConfig) {
        self.config = config
        self.items = config.items
    }

    deinit {
        timer?.invalidate()
    }

    var count: Int { items.count }
    var isLast: Bool { index >= items.count - 1 }
    var isRecording: Bool { recorder.isRecording }

    var currentItem: MockAuditionItem? {
        index < items.count ? items[index] : nil
    }

    var currentTitle: String {
        guard let item = currentItem else { return "" }
        return MockAuditionLogic.displayTitle(for: item, index: index, count: items.count, hideTitles: config.hideTitles)
    }

    // MARK: Flow

    func begin(allowRecording: Bool) {
        guard phase == .notStarted, !items.isEmpty else { return }
        startDate = Date()
        if config.recordWholeRun {
            if allowRecording {
                let name = TakeStore.newFileName(title: "Mock audition")
                do {
                    try recorder.start(fileName: name)
                } catch {
                    recordingNotice = String(localized: "Recording couldn't start (\(error.localizedDescription)). The run continues without it.")
                }
            } else {
                recordingNotice = String(localized: "Recording is off because the microphone isn't allowed for Auditioner.")
            }
        }
        startTimer()
        enter(index: 0)
    }

    /// Skips the rest of the preparation time.
    func startNow() {
        if case .prep = phase {
            startPlaying()
        }
    }

    /// Moves on to the next excerpt (call `finish` on the last one).
    func next() {
        guard !isLast else { return }
        enter(index: index + 1)
    }

    /// Ends the run and returns what to save.
    func finish() -> (items: [MockAuditionItem], recordingFileName: String?, totalSeconds: Double) {
        timer?.invalidate()
        timer = nil
        tick()
        var fileName: String? = nil
        if recorder.isRecording, let result = recorder.stop() {
            fileName = result.fileName
        }
        phase = .finished
        return (items, fileName, elapsedSeconds)
    }

    /// Ends the run and throws the recording away.
    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder.cancel()
        phase = .finished
    }

    // MARK: Private

    private func enter(index newIndex: Int) {
        index = newIndex
        if config.prepSeconds > 0 {
            prepEndDate = Date().addingTimeInterval(Double(config.prepSeconds))
            phase = .prep(remaining: config.prepSeconds)
        } else {
            startPlaying()
        }
    }

    private func startPlaying() {
        prepEndDate = nil
        phase = .playing
        let offset = recorder.isRecording ? recorder.currentTime : elapsedSeconds
        if index < items.count {
            items[index].startOffsetSeconds = max(0, offset)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let fresh = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(fresh, forMode: .common)
        timer = fresh
    }

    private func tick() {
        if let start = startDate {
            elapsedSeconds = Date().timeIntervalSince(start)
        }
        if case .prep = phase, let end = prepEndDate {
            let remaining = Int(ceil(end.timeIntervalSinceNow))
            if remaining <= 0 {
                startPlaying()
            } else if phase != .prep(remaining: remaining) {
                phase = .prep(remaining: remaining)
            }
        }
    }
}

/// The run itself: one big card per excerpt, prep countdown, next / finish, then the review.
struct MockAuditionRunView: View {
    let config: MockAuditionConfig

    @StateObject private var model: MockAuditionRunModel
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var savedRun: MockAuditionRun? = nil
    @State private var confirmStop: Bool = false
    @State private var didBegin: Bool = false

    init(config: MockAuditionConfig) {
        self.config = config
        _model = StateObject(wrappedValue: MockAuditionRunModel(config: config))
    }

    var body: some View {
        NavigationStack {
            if let run = savedRun {
                MockAuditionReviewView(run: run, onDone: { dismiss() })
            } else {
                runContent
            }
        }
        .interactiveDismissDisabled(savedRun == nil)
        .onAppear(perform: beginIfNeeded)
    }

    // MARK: Run screen

    private var runContent: some View {
        VStack(spacing: 24) {
            MockRunHeader(model: model)
            Spacer(minLength: 0)
            MockRunCard(model: model)
            Spacer(minLength: 0)
            if let notice = model.recordingNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.garnet)
                    .multilineTextAlignment(.center)
            }
            buttons
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Mock audition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop") { confirmStop = true }
            }
        }
        .confirmationDialog(Text("Stop the mock audition?"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Finish and review") { finish() }
            Button(role: .destructive) {
                model.cancel()
                dismiss()
            } label: {
                Text("Discard the run")
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .prep:
            Button {
                model.startNow()
            } label: {
                Label("Start now", systemImage: "forward.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
        case .playing:
            Button {
                if model.isLast {
                    finish()
                } else {
                    model.next()
                }
            } label: {
                Label {
                    if model.isLast {
                        Text("Finish")
                    } else {
                        Text("Next excerpt")
                    }
                } icon: {
                    Image(systemName: model.isLast ? "checkmark" : "arrow.right")
                }
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isLast ? Theme.garnet : Theme.teal)
        case .notStarted, .finished:
            ProgressView()
        }
    }

    // MARK: Actions

    private func beginIfNeeded() {
        guard !didBegin else { return }
        didBegin = true
        if config.recordWholeRun {
            AudioSessionCoordinator.shared.requestMicPermission { granted in
                model.begin(allowRecording: granted)
            }
        } else {
            model.begin(allowRecording: false)
        }
    }

    private func finish() {
        let result = model.finish()
        // D6, only while sharing is on: each excerpt counts under its own instrument, looked up in the
        // catalogue — not under the instrument in Settings. Ids the catalogue doesn't know are skipped.
        let practised: [Instrument: [String]] = MockAuditionLogic.practisedExcerpts(result.items) { (excerptId: String) -> Instrument? in
            catalog.excerpt(id: excerptId)?.instrument
        }
        for instrument in practised.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            TrendsTracker.shared.notePractised(excerptIds: practised[instrument] ?? [], instrument: instrument)
        }
        let run = MockAuditionRun(title: MockAuditionLogic.runTitle(date: Date()),
                                  itemsData: MockAuditionLogic.encode(result.items))
        run.recordingFileName = result.recordingFileName
        run.totalSeconds = result.totalSeconds
        modelContext.insert(run)
        try? modelContext.save()
        savedRun = run
    }
}

// MARK: - Pieces

struct MockRunHeader: View {
    @ObservedObject var model: MockAuditionRunModel
    @ObservedObject var recorder: TakeRecorder

    init(model: MockAuditionRunModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        HStack {
            Text("Excerpt \(model.index + 1) of \(model.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            Spacer()
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.garnet)
                        .frame(width: 10, height: 10)
                    Text("Recording")
                        .font(.subheadline)
                        .foregroundStyle(Theme.garnet)
                }
            }
            TimeText(seconds: model.elapsedSeconds, font: .subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

struct MockRunCard: View {
    @ObservedObject var model: MockAuditionRunModel
    @ObservedObject var recorder: TakeRecorder

    init(model: MockAuditionRunModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(model.currentTitle)
                .font(Theme.displayFont(.title))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            switch model.phase {
            case .prep(let remaining):
                Text("Get ready")
                    .font(.headline)
                    .foregroundStyle(Theme.inkSoft)
                Text("\(remaining)")
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brass)
                    .contentTransition(.numericText())
                    .animation(.default, value: remaining)
            case .playing:
                Text("Play")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.teal)
                if recorder.isRecording {
                    LevelMeterBar(level: recorder.level)
                        .frame(maxWidth: 220)
                }
            case .notStarted, .finished:
                EmptyView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
