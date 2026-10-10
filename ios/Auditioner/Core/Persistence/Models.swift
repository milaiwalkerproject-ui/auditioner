import Foundation
import SwiftData

// Local data. Kept CloudKit-friendly for v1.1 sync: no unique constraints,
// every property defaulted, no required relationships.

enum LibraryItemKind: String, Codable {
    case pdf, image, scan
}

@Model
final class LibraryItem {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var kindRaw: String = LibraryItemKind.pdf.rawValue
    /// File name inside Documents/Library/ (PDF or image).
    var fileName: String = ""
    var pageCount: Int = 1
    var linkedExcerptId: String?
    var lastOpenedPage: Int = 0

    init(title: String, kind: LibraryItemKind, fileName: String, pageCount: Int, linkedExcerptId: String? = nil) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.kindRaw = kind.rawValue
        self.fileName = fileName
        self.pageCount = pageCount
        self.linkedExcerptId = linkedExcerptId
    }

    var kind: LibraryItemKind { LibraryItemKind(rawValue: kindRaw) ?? .pdf }
}

/// Apple Pencil markup for one page of a library item (PKDrawing.dataRepresentation()).
@Model
final class PageAnnotation {
    var itemId: UUID = UUID()
    var pageIndex: Int = 0
    var drawingData: Data = Data()
    var updatedAt: Date = Date()

    init(itemId: UUID, pageIndex: Int, drawingData: Data) {
        self.itemId = itemId
        self.pageIndex = pageIndex
        self.drawingData = drawingData
        self.updatedAt = Date()
    }
}

enum ScoreOrigin: String, Codable {
    case curated   // checked transcription from content/musicxml
    case omr       // read from the user's scan by the server
    case edited    // OMR result corrected by the user
    case demo      // built-in demo (scale)
}

/// A piece of notation the user can play back (MusicXML), e.g. the result of a scan.
@Model
final class ScoreRecord {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var musicXML: String = ""
    var originRaw: String = ScoreOrigin.omr.rawValue
    var excerptId: String?
    var instrumentRaw: String = Instrument.cello.rawValue
    var sourceItemId: UUID?
    var preferredBPM: Double?
    var warnings: [String] = []
    /// JPEG of the marked excerpt the notes were read from (Documents/Scans/), for the correction editor.
    var scanImageFileName: String?

    init(title: String, musicXML: String, origin: ScoreOrigin, instrument: Instrument, excerptId: String? = nil, sourceItemId: UUID? = nil, warnings: [String] = []) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.musicXML = musicXML
        self.originRaw = origin.rawValue
        self.instrumentRaw = instrument.rawValue
        self.excerptId = excerptId
        self.sourceItemId = sourceItemId
        self.warnings = warnings
    }

    var origin: ScoreOrigin { ScoreOrigin(rawValue: originRaw) ?? .omr }
    var instrument: Instrument { Instrument(rawValue: instrumentRaw) ?? .cello }

    var document: ScoreDocument {
        ScoreDocument(id: id, title: title, musicXML: musicXML, origin: origin, instrument: instrument,
                      excerptId: excerptId, preferredBPM: preferredBPM, warnings: warnings)
    }
}

/// A "mark start / mark end" tap on a recording. Stored locally; submitted as a crowd vote later (M5).
@Model
final class TimestampMark {
    var excerptId: String = ""
    var recordingId: String = ""
    var youtubeId: String?
    var startSeconds: Double?
    var endSeconds: Double?
    var createdAt: Date = Date()
    var submitted: Bool = false

    init(excerptId: String, recordingId: String, youtubeId: String?, startSeconds: Double?, endSeconds: Double?) {
        self.excerptId = excerptId
        self.recordingId = recordingId
        self.youtubeId = youtubeId
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.createdAt = Date()
    }
}

/// One recording the player made of themselves (practice tools / record & compare).
@Model
final class PracticeTake {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    /// Audio file name inside Documents/Takes/.
    var fileName: String = ""
    var durationSeconds: Double = 0
    /// What was practised: a ScoreRecord id and/or a catalogue excerpt id.
    var scoreId: UUID?
    var excerptId: String?
    /// Tempo of the reference when the take was recorded (quarter = BPM), if recorded against it.
    var referenceBPM: Double?
    /// The take started this many beats into the reference (for A/B alignment).
    var referenceStartBeat: Double?
    var selfRating: Int?
    var notes: String = ""

    init(title: String, fileName: String, durationSeconds: Double) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.fileName = fileName
        self.durationSeconds = durationSeconds
    }
}

/// A mock audition run: an ordered list of excerpts played in one continuous recording.
@Model
final class MockAuditionRun {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    /// Items as JSON-encoded [MockAuditionItem] (kept as Data so the model stays CloudKit-friendly).
    var itemsData: Data = Data()
    /// Continuous recording of the whole run (Documents/Takes/), if recorded.
    var recordingFileName: String?
    var totalSeconds: Double = 0
    var overallRating: Int?
    var notes: String = ""

    init(title: String, itemsData: Data) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.itemsData = itemsData
    }
}

/// A "Report an error" / "Send feedback" message waiting to be sent to the server (or already sent).
@Model
final class FeedbackReport {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Where it was sent from, e.g. "excerpt-note:pitfalls", "excerpt-fact", "settings", "scan".
    var context: String = ""
    var excerptId: String?
    var message: String = ""
    var sentAt: Date?
    var lastError: String?

    init(context: String, excerptId: String?, message: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.context = context
        self.excerptId = excerptId
        self.message = message
    }
}

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        LibraryItem.self, PageAnnotation.self, ScoreRecord.self, TimestampMark.self,
        PracticeTake.self, MockAuditionRun.self, FeedbackReport.self,
    ]
}
