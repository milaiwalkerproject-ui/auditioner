import SwiftUI
import SwiftData

/// Resends queued feedback when the app starts and whenever it comes back to the front.
/// Applied once, to the root view in `AuditionerApp` (inside `.modelContainer`, so the
/// model context is in the environment).
struct FeedbackQueueFlusher: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                await FeedbackQueue.flush(context: modelContext)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await FeedbackQueue.flush(context: modelContext)
                    }
                }
            }
    }
}

extension View {
    /// Sends any "Report an error" / "Send feedback" messages still waiting on the device.
    func flushesFeedbackQueue() -> some View {
        modifier(FeedbackQueueFlusher())
    }
}
