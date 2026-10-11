import SwiftUI

/// Quiet one-line "Report an error" link for the bottom of an excerpt page's facts column
/// (context "excerpt-fact"). Caption-sized and right-aligned so it doesn't compete with the facts.
struct ExcerptReportErrorLink: View {
    let excerptId: String

    @State private var isReporting: Bool = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                isReporting = true
            } label: {
                Label("Spotted a mistake? Report an error", systemImage: "exclamationmark.bubble")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.slate)
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $isReporting) {
            ReportProblemSheet(context: "excerpt-fact", excerptId: excerptId)
        }
    }
}
