import Foundation
import SwiftData
import UIKit
import PDFKit
import UniformTypeIdentifiers

/// Why a part couldn't be added to the library. Plain words, shown in an alert.
enum LibraryError: LocalizedError {
    case unreadableFile
    case unsupportedType
    case noImages
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return String(localized: "This file couldn't be read. Try a PDF or a photo of your part.")
        case .unsupportedType:
            return String(localized: "Only PDF files and images can be added to My parts.")
        case .noImages:
            return String(localized: "No pages were scanned.")
        case .writeFailed:
            return String(localized: "The part couldn't be saved on this device.")
        }
    }
}

/// CONTRACT (owner: library agent). Files live in Documents/Library/. Images are stored as one-page PDFs
/// so the reader only deals with PDFs.
///
/// Two-step design so file work can run off the main thread:
///   prepareImport(from:) / prepareImport(images:)  – file I/O only, any thread, returns a `PreparedImport`;
///   commit(_:title:context:)                       – inserts the LibraryItem (main thread, with the ModelContext).
/// The contract one-shots `importFile(at:title:context:)` and `importImages(_:title:context:)` do both.
enum LibraryStore {
    /// Everything known about a file that has already been copied into Documents/Library/.
    struct PreparedImport {
        var fileName: String
        var kind: LibraryItemKind
        var pageCount: Int
        var suggestedTitle: String

        var fileURL: URL { LibraryStore.directory.appendingPathComponent(fileName) }
    }

    /// Longest page we make from an image, in PDF points (US letter / A4-ish). Bitmaps keep their full resolution.
    static let maxPageSize = CGSize(width: 612, height: 792)

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Library", isDirectory: true)
    }

    static func fileURL(for item: LibraryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    static func ensureDirectory() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw LibraryError.writeFailed
        }
    }

    // MARK: Contract one-shots

    /// Copies a PDF or image from Files / Share sheet / "Open in" (security-scoped URLs handled inside).
    @discardableResult
    static func importFile(at url: URL, title: String? = nil, context: ModelContext) throws -> LibraryItem {
        let prepared = try prepareImport(from: url)
        return try commit(prepared, title: title, context: context)
    }

    /// Stores scanned or picked page images as one multi-page PDF.
    @discardableResult
    static func importImages(_ images: [UIImage], title: String, context: ModelContext) throws -> LibraryItem {
        let prepared = try prepareImport(images: images, title: title)
        return try commit(prepared, title: title, context: context)
    }

    static func delete(_ item: LibraryItem, context: ModelContext) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        deleteAnnotations(for: item.id, context: context)
        context.delete(item)
        try? context.save()
    }

    // MARK: Two-step import

    /// File work only (no SwiftData). Safe on a background thread.
    static func prepareImport(from url: URL) throws -> PreparedImport {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        try ensureDirectory()
        let data = try coordinatedRead(url)
        let suggestedTitle = title(fromFileName: url)
        let fileName = UUID().uuidString + ".pdf"
        let destination = directory.appendingPathComponent(fileName)

        if looksLikePDF(url: url, data: data) {
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                throw LibraryError.unreadableFile
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw LibraryError.writeFailed
            }
            return PreparedImport(fileName: fileName, kind: .pdf, pageCount: document.pageCount,
                                  suggestedTitle: suggestedTitle)
        }

        if let image = UIImage(data: data) {
            try writePDF(images: [image], to: destination)
            return PreparedImport(fileName: fileName, kind: .image, pageCount: 1, suggestedTitle: suggestedTitle)
        }

        if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image), !type.conforms(to: .pdf) {
            throw LibraryError.unsupportedType
        }
        throw LibraryError.unreadableFile
    }

    /// Writes the images as one PDF into Documents/Library/. Safe on a background thread.
    static func prepareImport(images: [UIImage], title: String) throws -> PreparedImport {
        guard !images.isEmpty else { throw LibraryError.noImages }
        try ensureDirectory()
        let fileName = UUID().uuidString + ".pdf"
        let destination = directory.appendingPathComponent(fileName)
        try writePDF(images: images, to: destination)
        return PreparedImport(fileName: fileName, kind: .scan, pageCount: images.count, suggestedTitle: title)
    }

    /// Inserts the LibraryItem for a prepared file and saves. Call with the main ModelContext.
    @discardableResult
    static func commit(_ prepared: PreparedImport, title: String?, context: ModelContext) throws -> LibraryItem {
        let cleanTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? prepared.suggestedTitle : cleanTitle
        let item = LibraryItem(title: finalTitle, kind: prepared.kind, fileName: prepared.fileName,
                               pageCount: prepared.pageCount)
        context.insert(item)
        do {
            try context.save()
        } catch {
            context.delete(item)
            try? FileManager.default.removeItem(at: prepared.fileURL)
            throw error
        }
        return item
    }

    /// Removes a prepared file that will not be committed (e.g. the user cancelled).
    static func discard(_ prepared: PreparedImport) {
        try? FileManager.default.removeItem(at: prepared.fileURL)
    }

    // MARK: Pure helpers

    /// Builds a multi-page PDF, one page per image, each page sized to the image (fitted to `maxPageSize`).
    static func pdfData(images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw LibraryError.noImages }
        let firstSize = pageSize(for: images[0].size)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        let data = renderer.pdfData { context in
            for image in images {
                let size = pageSize(for: image.size)
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                UIColor.white.setFill()
                context.fill(bounds)
                image.draw(in: bounds)
            }
        }
        return data
    }

    /// Writes `pdfData(images:)` to `destination`. Used by imports and by unit tests (temp directory).
    static func writePDF(images: [UIImage], to destination: URL) throws {
        let data = try pdfData(images: images)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw LibraryError.writeFailed
        }
    }

    /// PDF page size (points) for an image: scaled down to fit a letter-sized page, never scaled up.
    static func pageSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return maxPageSize }
        let isLandscape = imageSize.width > imageSize.height
        let limit = isLandscape
            ? CGSize(width: maxPageSize.height, height: maxPageSize.width)
            : maxPageSize
        let factor = min(1, limit.width / imageSize.width, limit.height / imageSize.height)
        return CGSize(width: (imageSize.width * factor).rounded(), height: (imageSize.height * factor).rounded())
    }

    /// "Brahms_Symphony-2_cello.pdf" style names → "Brahms Symphony 2 cello".
    static func title(fromFileName url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let spaced = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = spaced.split(whereSeparator: { $0 == " " }).map(String.init)
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? String(localized: "Untitled part") : joined
    }

    static func looksLikePDF(url: URL, data: Data) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) { return true }
        let magic: [UInt8] = [0x25, 0x50, 0x44, 0x46] // "%PDF"
        guard data.count >= magic.count else { return false }
        return Array(data.prefix(magic.count)) == magic
    }

    // MARK: Private

    /// Reads through NSFileCoordinator so iCloud / provider files are downloaded first.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var readError: Error?
        var result: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            do {
                result = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }
        if let data = result, !data.isEmpty {
            return data
        }
        if coordinatorError != nil || readError != nil {
            throw LibraryError.unreadableFile
        }
        throw LibraryError.unreadableFile
    }

    private static func deleteAnnotations(for itemId: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<PageAnnotation>(predicate: #Predicate<PageAnnotation> { $0.itemId == itemId })
        guard let annotations = try? context.fetch(descriptor) else { return }
        for annotation in annotations {
            context.delete(annotation)
        }
    }
}
