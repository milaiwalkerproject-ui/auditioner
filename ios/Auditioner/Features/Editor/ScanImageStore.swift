import Foundation
import UIKit

/// JPEGs of the marked excerpts the server read notes from, kept in Documents/Scans/ so the
/// correction editor can show the original picture next to the notes. Files are named by UUID;
/// `ScoreRecord.scanImageFileName` points at them.
enum ScanImageStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func ensureDirectory() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    /// Writes the JPEG and returns its file name. Safe on any thread.
    static func save(jpeg: Data) throws -> String {
        try ensureDirectory()
        let fileName = UUID().uuidString + ".jpg"
        try jpeg.write(to: url(for: fileName), options: .atomic)
        return fileName
    }

    static func loadImage(named fileName: String) -> UIImage? {
        guard !fileName.isEmpty else { return nil }
        let fileURL = url(for: fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    static func delete(named fileName: String) {
        guard !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
