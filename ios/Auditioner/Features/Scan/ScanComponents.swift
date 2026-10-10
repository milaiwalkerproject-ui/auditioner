import SwiftUI
import UIKit
import VisionKit
import Vision
import PDFKit

// CONTRACT (owner: scan agent). Building blocks used by the hero flow.
//
// Public API (type names and initializers are fixed):
//   DocumentCameraView(onFinish:onCancel:)        – system document camera, returns page images
//   ExcerptCropView(image:onCrop:onCancel:)       – drag a box around the excerpt (see ExcerptCropView.swift)
//   TextRecognizer.recognizeLines(in:) async      – on-device OCR lines in reading order
//   PDFPageRenderer.pageCount(url:) / render(url:pageIndex:dpi:) / thumbnail(url:pageIndex:maxPixelSize:)

// MARK: - Document camera

/// System document camera (VisionKit). Returns de-skewed page images.
/// On devices without document-camera support (and in the simulator) a short message is shown instead.
struct DocumentCameraView: View {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    var body: some View {
        if VNDocumentCameraViewController.isSupported {
            DocumentCameraRepresentable(onFinish: onFinish, onCancel: onCancel)
                .ignoresSafeArea()
        } else {
            DocumentCameraUnsupportedView(onCancel: onCancel)
        }
    }
}

private struct DocumentCameraRepresentable: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        context.coordinator.onFinish = onFinish
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var onFinish: ([UIImage]) -> Void
        var onCancel: () -> Void
        private var hasFinished = false

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard !hasFinished else { return }
            hasFinished = true
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard !hasFinished else { return }
            hasFinished = true
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            guard !hasFinished else { return }
            hasFinished = true
            onCancel()
        }
    }
}

private struct DocumentCameraUnsupportedView: View {
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkSoft)
            Text("Scanning with the camera isn't available on this device.")
                .font(.headline)
            Text("You can still add a PDF or a photo of your part from Files or Photos.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            Button("OK") { onCancel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
    }
}

// MARK: - Text recognition

/// On-device text recognition (Vision) for titles, composer names, tempo words.
enum TextRecognizer {
    /// One recognised line and its Vision bounding box (normalised, origin bottom-left).
    struct RecognizedLine: Equatable {
        var text: String
        var box: CGRect
    }

    /// Languages we ask Vision for, in preference order (only those the device supports are used).
    static let preferredLanguages: [String] = ["en-US", "it-IT", "de-DE", "fr-FR"]

    /// Generic musical vocabulary that often appears on parts; helps the language model, no facts involved.
    static let customWords: [String] = [
        "Allegro", "Allegretto", "Andante", "Andantino", "Adagio", "Adagietto", "Moderato", "Presto",
        "Prestissimo", "Vivace", "Vivo", "Largo", "Larghetto", "Lento", "Grave", "Maestoso", "Animato",
        "Sostenuto", "Cantabile", "Espressivo", "Dolce", "Marcato", "Scherzo", "Trio", "Finale", "Rondo",
        "Menuetto", "Minuetto", "Marcia", "Tempo", "Primo", "Molto", "Poco", "Assai", "Brio", "Solo", "Tutti",
        "Pizz.", "Arco", "Divisi", "Violoncello", "Cello", "Violoncelli", "Contrabasso", "Kontrabass",
        "Violine", "Violino", "Viola", "Bratsche", "Flauto", "Oboe", "Clarinetto", "Klarinette", "Fagotto",
        "Corno", "Tromba", "Trombone", "Posaune", "Timpani", "Pauken", "Symphony", "Symphonie", "Sinfonie",
        "Sinfonia", "Ouvertüre", "Ouverture", "Overture", "Konzert", "Concerto", "Suite",
    ]

    /// Recognises text lines in an image, top candidate per line, in reading order
    /// (top to bottom, then left to right). Runs Vision off the main thread.
    static func recognizeLines(in image: UIImage) async -> [String] {
        let upright = ScanImageNormalizer.normalized(image)
        guard let cgImage = upright.cgImage else { return [] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = recognizeSync(cgImage: cgImage)
                continuation.resume(returning: lines)
            }
        }
    }

    /// Synchronous Vision call. Safe to call from any thread.
    static func recognizeSync(cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = customWords
        if let supported = try? request.supportedRecognitionLanguages() {
            let chosen = preferredLanguages.filter { supported.contains($0) }
            if !chosen.isEmpty {
                request.recognitionLanguages = chosen
            }
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations: [VNRecognizedTextObservation] = (request.results ?? []).compactMap { result in
            result as? VNRecognizedTextObservation
        }
        var lines: [RecognizedLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(RecognizedLine(text: text, box: observation.boundingBox))
        }
        return orderedForReading(lines)
    }

    /// Pure: sorts Vision lines top-to-bottom (Vision's y axis points up), grouping lines that share a row
    /// and ordering those left-to-right.
    static func orderedForReading(_ lines: [RecognizedLine]) -> [String] {
        let byHeight = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in byHeight {
            if let anchor = rows.last?.first {
                let tolerance = max(min(anchor.box.height, line.box.height) * 0.5, 0.005)
                if abs(anchor.box.midY - line.box.midY) <= tolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        var result: [String] = []
        for row in rows {
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            for line in ordered {
                result.append(line.text)
            }
        }
        return result
    }
}

// MARK: - Image orientation

/// Redraws a UIImage so its pixel data is `.up`; needed before cropping CGImages or feeding Vision.
enum ScanImageNormalizer {
    static func normalized(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil {
            return image
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return redrawn
    }

    /// JPEG data for upload (orientation already baked in).
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.9) -> Data? {
        normalized(image).jpegData(compressionQuality: quality)
    }
}

// MARK: - PDF rendering

/// Renders PDF pages to images for cropping / OMR.
enum PDFPageRenderer {
    static func pageCount(url: URL) -> Int {
        guard let document = PDFDocument(url: url) else { return 0 }
        return document.pageCount
    }

    /// Renders one page to a bitmap at the given resolution (72 dpi = 1 pixel per PDF point).
    static func render(url: URL, pageIndex: Int, dpi: CGFloat = 300) -> UIImage? {
        guard let document = PDFDocument(url: url) else { return nil }
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return nil }
        return render(page: page, dpi: dpi)
    }

    static func render(page: PDFPage, dpi: CGFloat) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, dpi > 0 else { return nil }
        let scale = dpi / 72
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation != 0 {
            // Let PDFKit apply the page's /Rotate for us. A square target keeps the long side at full resolution
            // whatever orientation the page ends up in; the result keeps the page's aspect ratio.
            let side = max(bounds.width, bounds.height) * scale
            return page.thumbnail(of: CGSize(width: side, height: side), for: .mediaBox)
        }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
        return image
    }

    /// Small preview of a page, longest side `maxPixelSize` pixels. Rotation is handled by PDFKit.
    static func thumbnail(url: URL, pageIndex: Int = 0, maxPixelSize: CGFloat = 240) -> UIImage? {
        guard let document = PDFDocument(url: url) else { return nil }
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, maxPixelSize > 0 else { return nil }
        let longest = max(bounds.width, bounds.height)
        let factor = maxPixelSize / longest
        let size = CGSize(width: max(1, bounds.width * factor), height: max(1, bounds.height * factor))
        let rotation = ((page.rotation % 360) + 360) % 360
        let target = (rotation == 90 || rotation == 270) ? CGSize(width: size.height, height: size.width) : size
        return page.thumbnail(of: target, for: .mediaBox)
    }
}
