import Foundation
import AVFoundation
import SwiftData

/// Where the player's own recordings live (Documents/Takes/) and how their files are named.
enum TakeStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Takes", isDirectory: true)
    }

    static func ensureDirectory() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    static func fileURL(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func fileURL(for take: PracticeTake) -> URL {
        fileURL(fileName: take.fileName)
    }

    static func recordingURL(for run: MockAuditionRun) -> URL? {
        guard let name = run.recordingFileName, !name.isEmpty else { return nil }
        return fileURL(fileName: name)
    }

    static func fileExists(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(fileName: fileName).path)
    }

    // MARK: Naming (pure)

    /// Letters and digits of `title` joined by dashes; "Take" when nothing is left.
    static func sanitizedBase(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var cleaned = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !cleaned.isEmpty {
                cleaned += "-"
                lastWasDash = true
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        if cleaned.isEmpty { cleaned = "Take" }
        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60))
            while cleaned.hasSuffix("-") { cleaned.removeLast() }
        }
        return cleaned
    }

    /// "yyyyMMdd-HHmmss" in `timeZone`.
    static func timeStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// "Strauss-Don-Juan-20261011-143005.m4a" — the take's file name for a title and a moment.
    static func fileName(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        sanitizedBase(title) + "-" + timeStamp(date, timeZone: timeZone) + ".m4a"
    }

    /// `preferred`, or "-2", "-3" … inserted before the extension until `exists` says the name is free.
    static func uniqueFileName(preferred: String, exists: (String) -> Bool) -> String {
        guard exists(preferred) else { return preferred }
        let ext = (preferred as NSString).pathExtension
        let base = (preferred as NSString).deletingPathExtension
        var n = 2
        while n < 1000 {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
        return ext.isEmpty ? "\(base)-\(UUID().uuidString)" : "\(base)-\(UUID().uuidString).\(ext)"
    }

    /// A free file name in Documents/Takes/ for a new take.
    static func newFileName(title: String, date: Date = Date()) -> String {
        uniqueFileName(preferred: fileName(title: title, date: date), exists: { fileExists(fileName: $0) })
    }

    // MARK: Files

    /// Length of an audio file in seconds, read from its header.
    static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func delete(_ take: PracticeTake, context: ModelContext) {
        try? FileManager.default.removeItem(at: fileURL(for: take))
        context.delete(take)
        try? context.save()
    }

    static func delete(_ run: MockAuditionRun, context: ModelContext) {
        if let url = recordingURL(for: run) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(run)
        try? context.save()
    }
}
