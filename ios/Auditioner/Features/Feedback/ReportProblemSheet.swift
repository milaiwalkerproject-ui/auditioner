import SwiftUI

/// CONTRACT (owner: feedback builder): "Report an error" / "Send feedback" sheet.
/// `context` says where it came from (e.g. "excerpt-note:pitfalls", "excerpt-fact", "settings").
struct ReportProblemSheet: View {
    let context: String
    var excerptId: String? = nil

    var body: some View {
        Text("Report a problem")
    }
}
