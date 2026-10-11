import SwiftUI
import SwiftData

/// "Report an error" (from excerpt pages) / "Send feedback" (everywhere else).
///
/// `context` says where it came from, e.g. "excerpt-note:pitfalls", "excerpt-fact", "settings",
/// "scan"; `excerptId` is set when it is about one excerpt. The message is saved on the device
/// first (`FeedbackReport`), then sent to the Auditioner server. If the server isn't set up or
/// can't be reached the report stays queued and `FeedbackQueue.flush` retries later.
///
/// There is no public contact email: this sheet is how players reach us.
struct ReportProblemSheet: View {
    let context: String
    var excerptId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var catalog: CatalogStore

    @State private var message: String = ""
    @State private var isSending: Bool = false
    @State private var showResult: Bool = false
    @State private var outcome: FeedbackQueue.Outcome = .queued

    var body: some View {
        NavigationStack {
            Form {
                aboutSection
                messageSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle(FeedbackLogic.title(for: context))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    sendButton
                }
            }
            .alert(Text(outcome.title), isPresented: $showResult) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text(outcome.text)
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    // MARK: What it's about

    private var excerptLine: String? {
        guard let id = FeedbackLogic.cleanExcerptId(excerptId) else { return nil }
        if let excerpt = catalog.excerpt(id: id) {
            return "\(excerpt.workHeading) — \(excerpt.subtitle)"
        }
        return id
    }

    private var aboutSection: some View {
        Section {
            if let excerptLine = excerptLine {
                FeedbackAboutRow(label: String(localized: "Excerpt"), value: excerptLine)
            }
            FeedbackAboutRow(label: String(localized: "Where"), value: FeedbackLogic.contextDescription(context))
        } header: {
            Text("What this is about")
        }
    }

    // MARK: Message

    private var messageSection: some View {
        Section {
            TextEditor(text: $message)
                .frame(minHeight: 140)
                .disabled(isSending)
                .onChange(of: message) { _, newValue in
                    let clamped: String = FeedbackLogic.clamped(newValue)
                    if clamped != newValue {
                        message = clamped
                    }
                }
            HStack {
                Spacer(minLength: 0)
                Text(FeedbackLogic.counterText(message))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkFaint)
            }
        } header: {
            Text(FeedbackLogic.prompt(for: context))
        } footer: {
            Text("Don't include personal details. We see your message, the excerpt and the app version — nothing else.")
        }
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            if isSending {
                ProgressView()
            } else {
                Text("Send")
            }
        }
        .disabled(isSending || !FeedbackLogic.canSend(message))
    }

    // MARK: Sending

    private func send() {
        let text: String = FeedbackLogic.cleanMessage(message)
        guard !text.isEmpty, !isSending else { return }
        isSending = true

        let report = FeedbackReport(context: FeedbackLogic.cleanContext(context),
                                    excerptId: FeedbackLogic.cleanExcerptId(excerptId),
                                    message: text)
        modelContext.insert(report)
        try? modelContext.save()

        let client: APIClient = APIClient.fromSettings()
        Task {
            let result: FeedbackQueue.Outcome = await FeedbackQueue.send(report, client: client)
            try? modelContext.save()
            isSending = false
            outcome = result
            showResult = true
        }
    }
}

/// Label on the left, value on the right (wraps onto several lines for long excerpt titles).
private struct FeedbackAboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}
