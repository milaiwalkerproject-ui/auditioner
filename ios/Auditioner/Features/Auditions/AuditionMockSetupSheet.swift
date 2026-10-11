import SwiftUI
import SwiftData

/// Pure: which checklist lines go into a mock audition and under what title.
enum AuditionMockLogic {
    struct Source: Equatable {
        var rawText: String
        var excerptId: String?
        var category: String
        /// "Strauss · Don Juan — Opening" when the line is linked to the catalogue.
        var excerptTitle: String?
    }

    /// Sight-reading is left out (it cannot be rehearsed); linked lines use the catalogue title.
    static func mockItems(_ sources: [Source]) -> [MockAuditionItem] {
        sources
            .filter { AuditionItemCategory(raw: $0.category).isPractisable }
            .map { source in
                MockAuditionItem(title: source.excerptTitle ?? source.rawText, excerptId: source.excerptId)
            }
    }
}

/// "Start mock audition with this list": the list is already filled in; the player sets the rules and starts.
/// (The practice tab's `MockAuditionSetupView` keeps its own list, so this small sheet reuses its rules and run screen.)
struct AuditionMockSetupSheet: View {
    let items: [MockAuditionItem]
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var order: MockAuditionOrder = .random
    @State private var hideTitles: Bool = true
    @State private var prepSeconds: Int = 15
    @State private var recordWholeRun: Bool = true
    @State private var runRequest: MockAuditionRunRequest? = nil

    var body: some View {
        Form {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    Text(pair.element.title)
                        .lineLimit(2)
                }
            } header: {
                Text("Excerpts (\(items.count))")
            } footer: {
                Text("Sight-reading lines are left out. Edit the list on the audition screen.")
            }
            rulesSection
            Section {
                Button {
                    start()
                } label: {
                    Label("Start mock audition", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(items.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(title.isEmpty ? String(localized: "Mock audition") : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .fullScreenCover(item: $runRequest) { request in
            MockAuditionRunView(config: request.config)
        }
    }

    private var rulesSection: some View {
        Section {
            Picker(selection: $order) {
                ForEach(MockAuditionOrder.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            } label: {
                Text("Order")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $hideTitles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behind the screen")
                    Text("Titles are hidden: you only see “Excerpt 2 of 6”.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Time to prepare between excerpts")
                Picker(selection: $prepSeconds) {
                    ForEach(MockAuditionLogic.prepChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? String(localized: "None") : "\(seconds) s").tag(seconds)
                    }
                } label: {
                    Text("Time to prepare")
                }
                .pickerStyle(.segmented)
            }
            Toggle(isOn: $recordWholeRun) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record the whole run")
                    Text("One continuous recording, with the start of each excerpt marked.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        } header: {
            Text("Rules")
        }
    }

    private func start() {
        guard !items.isEmpty else { return }
        let ordered: [MockAuditionItem] = MockAuditionLogic.ordered(items, order: order)
        let config = MockAuditionConfig(items: ordered, hideTitles: hideTitles, prepSeconds: prepSeconds, recordWholeRun: recordWholeRun)
        runRequest = MockAuditionRunRequest(config: config)
    }
}
