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

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [LibraryItem.self, PageAnnotation.self, ScoreRecord.self, TimestampMark.self]
}
