import Foundation
import SwiftData
import Combine

/// Reads and writes the user's own "Mark start / Mark end" taps (one `TimestampMark` per
/// excerpt + recording). Stored locally; submitted as a crowd vote later (M5).
enum TimestampMarkStore {
    static func existing(excerptId: String, recordingId: String, in context: ModelContext) -> TimestampMark? {
        let descriptor = FetchDescriptor<TimestampMark>()
        let all: [TimestampMark] = (try? context.fetch(descriptor)) ?? []
        let matching = all.filter { $0.excerptId == excerptId && $0.recordingId == recordingId }
        return matching.sorted { $0.createdAt > $1.createdAt }.first
    }

    /// Creates or updates the mark for this excerpt + recording and saves the context.
    @discardableResult
    static func save(excerptId: String, recordingId: String, youtubeId: String?,
                     start: Double?, end: Double?, in context: ModelContext) throws -> TimestampMark {
        if let mark = existing(excerptId: excerptId, recordingId: recordingId, in: context) {
            mark.startSeconds = start
            mark.endSeconds = end
            mark.youtubeId = youtubeId
            mark.submitted = false
            try context.save()
            return mark
        }
        let mark = TimestampMark(excerptId: excerptId, recordingId: recordingId, youtubeId: youtubeId,
                                 startSeconds: start, endSeconds: end)
        context.insert(mark)
        try context.save()
        return mark
    }
}

/// The user's marks for one recording, as view state. Load once on appear, save on each tap.
final class RecordingMarks: ObservableObject {
    let excerptId: String
    let recordingId: String
    let youtubeId: String?

    @Published private(set) var start: Double? = nil
    @Published private(set) var end: Double? = nil
    @Published var saveError: String? = nil

    init(excerpt: Excerpt, recording: Recording) {
        self.excerptId = excerpt.id
        self.recordingId = recording.id
        self.youtubeId = recording.youtubeId
    }

    /// Both marks set and in order → an A–B loop range.
    var loopRange: (start: Double, end: Double)? {
        guard let start = start, let end = end, end > start + 0.25 else { return nil }
        return (start, end)
    }

    func load(from context: ModelContext) {
        guard let mark = TimestampMarkStore.existing(excerptId: excerptId, recordingId: recordingId, in: context) else { return }
        start = mark.startSeconds
        end = mark.endSeconds
    }

    func setStart(_ seconds: Double, in context: ModelContext) {
        start = max(0, seconds)
        persist(in: context)
    }

    func setEnd(_ seconds: Double, in context: ModelContext) {
        end = max(0, seconds)
        persist(in: context)
    }

    private func persist(in context: ModelContext) {
        do {
            try TimestampMarkStore.save(excerptId: excerptId, recordingId: recordingId, youtubeId: youtubeId,
                                        start: start, end: end, in: context)
            saveError = nil
        } catch {
            saveError = String(localized: "Couldn't save your mark on this device.")
        }
    }
}
