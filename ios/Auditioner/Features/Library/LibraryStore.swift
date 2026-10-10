import Foundation
import SwiftData
import UIKit

/// CONTRACT (owner: library agent). Files live in Documents/Library/. Images are stored as one-page PDFs
/// so the reader only deals with PDFs.
enum LibraryStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Library", isDirectory: true)
    }

    static func fileURL(for item: LibraryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    /// Copies a PDF or image from Files / Share sheet / "Open in" (security-scoped URLs handled inside).
    @discardableResult
    static func importFile(at url: URL, title: String? = nil, context: ModelContext) throws -> LibraryItem {
        throw CocoaError(.featureUnsupported)
    }

    /// Stores scanned or picked page images as one multi-page PDF.
    @discardableResult
    static func importImages(_ images: [UIImage], title: String, context: ModelContext) throws -> LibraryItem {
        throw CocoaError(.featureUnsupported)
    }

    static func delete(_ item: LibraryItem, context: ModelContext) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        context.delete(item)
    }
}
