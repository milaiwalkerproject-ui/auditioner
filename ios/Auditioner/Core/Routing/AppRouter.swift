import SwiftUI

enum AppTab: Hashable {
    case excerpts, library, practice, settings
}

/// Where a scan starts from.
enum ScanSource: Hashable {
    case camera
    case files
    case photos
    case libraryItem(UUID)
}

/// Everything the scan → reference-audio flow needs to start.
struct ScanContext: Identifiable, Hashable {
    let id = UUID()
    var source: ScanSource
    /// Set when the user starts from an excerpt page ("Scan my part"), so identification can be skipped.
    var excerpt: Excerpt?
}

/// App-wide navigation state.
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .excerpts
    @Published var scanContext: ScanContext?
    @Published var practiceDocument: ScoreDocument?
    /// Excerpt opened from elsewhere (e.g. after a scan was identified).
    @Published var openedExcerptId: String?

    func startScan(_ source: ScanSource, excerpt: Excerpt? = nil) {
        scanContext = ScanContext(source: source, excerpt: excerpt)
    }

    func openPractice(_ document: ScoreDocument) {
        scanContext = nil
        practiceDocument = document
    }
}
