import SwiftUI
import UIKit

// CONTRACT (owner: scan agent). Building blocks used by the hero flow.

/// System document camera (VisionKit). Returns de-skewed page images.
struct DocumentCameraView: View {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void
    var body: some View { Text("Camera") }
}

/// Lets the user drag a box around the excerpt on a page image.
struct ExcerptCropView: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void
    var onCancel: () -> Void
    var body: some View { Image(uiImage: image).resizable().scaledToFit() }
}

/// On-device text recognition (Vision) for titles, composer names, tempo words.
enum TextRecognizer {
    static func recognizeLines(in image: UIImage) async -> [String] { [] }
}

/// Renders PDF pages to images for cropping / OMR.
enum PDFPageRenderer {
    static func pageCount(url: URL) -> Int { 0 }
    static func render(url: URL, pageIndex: Int, dpi: CGFloat = 300) -> UIImage? { nil }
}
