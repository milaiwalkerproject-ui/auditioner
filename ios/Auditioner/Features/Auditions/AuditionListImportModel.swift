import Foundation
import Combine
import UIKit
import PDFKit

/// Reads a repertoire list on the device: pages (camera, PDF, photo) → Vision text lines → parsed
/// items → review lines. Nothing is uploaded, no model is called, and the pictures are not kept
/// (PLAN F4: "file deleted after reading" — here it is never written at all).
@MainActor
final class AuditionListImportModel: ObservableObject {
    enum Stage: Equatable {
        case choose
        case pasting
        case loading(String)
        case review
        case failed(String)
    }

    @Published var stage: Stage = .choose
    @Published var lines: [AuditionReviewLine] = []

    /// How many pages of a document we read; a repertoire list is rarely longer.
    static let maxPages: Int = 8

    func startPasting() {
        stage = .pasting
    }

    func backToChoices() {
        stage = .choose
    }

    func read(images: [UIImage], pool: [Excerpt]) {
        guard !images.isEmpty else {
            stage = .failed(String(localized: "No pages were scanned."))
            return
        }
        stage = .loading(String(localized: "Reading the list on this device…"))
        let pages: [UIImage] = Array(images.prefix(Self.maxPages))
        Task {
            var all: [String] = []
            for page in pages {
                let recognised: [String] = await TextRecognizer.recognizeLines(in: page)
                all.append(contentsOf: recognised)
            }
            self.finish(lines: all, pool: pool)
        }
    }

    func read(fileURL: URL, pool: [Excerpt]) {
        stage = .loading(String(localized: "Opening the file…"))
        let limit: Int = AuditionListImportModel.maxPages
        Task {
            let pages: [UIImage] = await Task.detached(priority: .userInitiated) {
                AuditionListPages.images(from: fileURL, maxPages: limit)
            }.value
            guard !pages.isEmpty else {
                self.stage = .failed(String(localized: "This file couldn't be read. Try a PDF or a picture of the list, or paste its text."))
                return
            }
            self.read(images: pages, pool: pool)
        }
    }

    func read(photoData: [Data], pool: [Excerpt]) {
        stage = .loading(String(localized: "Opening the photos…"))
        Task {
            let images: [UIImage] = await Task.detached(priority: .userInitiated) {
                AuditionListPages.images(from: photoData)
            }.value
            guard !images.isEmpty else {
                self.stage = .failed(String(localized: "These photos couldn't be read."))
                return
            }
            self.read(images: images, pool: pool)
        }
    }

    func read(text: String, pool: [Excerpt]) {
        finish(lines: text.components(separatedBy: CharacterSet.newlines), pool: pool)
    }

    private func finish(lines recognised: [String], pool: [Excerpt]) {
        let parsed: [ParsedListItem] = AuditionListParser.parse(lines: recognised)
        guard !parsed.isEmpty else {
            stage = .failed(String(localized: "No list lines were found. Try a sharper picture, or paste the text of the list."))
            return
        }
        lines = AuditionReviewLogic.lines(from: parsed, pool: pool)
        stage = .review
    }
}

/// Page images from a picked file or photos. Runs off the main thread; keeps nothing on disk.
enum AuditionListPages {
    static func images(from url: URL, maxPages: Int) -> [UIImage] {
        let accessed: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        if let document = PDFDocument(data: data) {
            var result: [UIImage] = []
            let count: Int = min(document.pageCount, max(1, maxPages))
            for index in 0..<count {
                guard let page = document.page(at: index) else { continue }
                if let image = PDFPageRenderer.render(page: page, dpi: 200) {
                    result.append(image)
                }
            }
            return result
        }
        if let image = UIImage(data: data) {
            return [ScanImageNormalizer.normalized(image)]
        }
        return []
    }

    static func images(from photoData: [Data]) -> [UIImage] {
        var result: [UIImage] = []
        for data in photoData {
            if let image = UIImage(data: data) {
                result.append(ScanImageNormalizer.normalized(image))
            }
        }
        return result
    }
}
