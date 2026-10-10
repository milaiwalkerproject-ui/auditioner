import XCTest
import UIKit
import PDFKit
@testable import Auditioner

final class ScanLibraryTests: XCTestCase {

    // MARK: - Crop geometry: aspect-fit letterboxing

    func testFittedRectPortraitImageInSquareContainer() {
        let fitted = CropGeometry.fittedRect(imageSize: CGSize(width: 1000, height: 2000),
                                             in: CGSize(width: 300, height: 300))
        XCTAssertEqual(fitted.minX, 75, accuracy: 0.001)
        XCTAssertEqual(fitted.minY, 0, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 150, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 300, accuracy: 0.001)
    }

    func testFittedRectLandscapeImageInSquareContainer() {
        let fitted = CropGeometry.fittedRect(imageSize: CGSize(width: 2000, height: 1000),
                                             in: CGSize(width: 300, height: 300))
        XCTAssertEqual(fitted.minX, 0, accuracy: 0.001)
        XCTAssertEqual(fitted.minY, 75, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 300, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 150, accuracy: 0.001)
    }

    func testFittedRectZeroSizesIsZero() {
        XCTAssertEqual(CropGeometry.fittedRect(imageSize: .zero, in: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(CropGeometry.fittedRect(imageSize: CGSize(width: 10, height: 10), in: .zero), .zero)
    }

    // MARK: - Crop geometry: view → pixel conversion

    func testWholeFittedAreaMapsToWholeImagePortrait() {
        let imageSize = CGSize(width: 1000, height: 2000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let pixels = CropGeometry.pixelRect(fromViewRect: fitted, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 1000, height: 2000))
    }

    func testWholeFittedAreaMapsToWholeImageLandscape() {
        let imageSize = CGSize(width: 2000, height: 1000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let pixels = CropGeometry.pixelRect(fromViewRect: fitted, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 2000, height: 1000))
    }

    func testPartialSelectionAccountsForLetterboxOffset() {
        // Portrait 1000×2000 fitted into 300×300 → occupies x 75…225, y 0…300.
        let imageSize = CGSize(width: 1000, height: 2000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let view = CGRect(x: 112.5, y: 75, width: 75, height: 150)
        let pixels = CropGeometry.pixelRect(fromViewRect: view, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 250, y: 500, width: 500, height: 1000))
    }

    func testPartialSelectionLandscapeAccountsForVerticalLetterbox() {
        // Landscape 2000×1000 fitted into 300×300 → occupies x 0…300, y 75…225.
        let imageSize = CGSize(width: 2000, height: 1000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let view = CGRect(x: 30, y: 90, width: 60, height: 30)
        let pixels = CropGeometry.pixelRect(fromViewRect: view, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 200, y: 100, width: 400, height: 200))
    }

    func testPixelRectAccountsForImageScale() {
        // 500×1000 points at 2× = 1000×2000 pixels.
        let imageSize = CGSize(width: 500, height: 1000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let view = CGRect(x: 112.5, y: 75, width: 75, height: 150)
        let pixels = CropGeometry.pixelRect(fromViewRect: view, fitted: fitted, imageSize: imageSize, scale: 2)
        XCTAssertEqual(pixels, CGRect(x: 250, y: 500, width: 500, height: 1000))
    }

    func testPixelRectClampsToImageBounds() {
        let imageSize = CGSize(width: 1000, height: 2000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let view = CGRect(x: -50, y: -50, width: 400, height: 400) // far beyond the fitted page
        let pixels = CropGeometry.pixelRect(fromViewRect: view, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertEqual(pixels, CGRect(x: 0, y: 0, width: 1000, height: 2000))
    }

    func testPixelRectOutsidePageIsEmpty() {
        let imageSize = CGSize(width: 1000, height: 2000)
        let fitted = CropGeometry.fittedRect(imageSize: imageSize, in: CGSize(width: 300, height: 300))
        let view = CGRect(x: 0, y: 0, width: 50, height: 50) // in the left letterbox band only
        let pixels = CropGeometry.pixelRect(fromViewRect: view, fitted: fitted, imageSize: imageSize, scale: 1)
        XCTAssertTrue(pixels.isEmpty)
    }

    func testUnitAndViewRectsRoundTrip() {
        let fitted = CGRect(x: 75, y: 0, width: 150, height: 300)
        let unit = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        let view = CropGeometry.viewRect(fromUnit: unit, fitted: fitted)
        XCTAssertEqual(view.minX, 90, accuracy: 0.001)
        XCTAssertEqual(view.minY, 60, accuracy: 0.001)
        XCTAssertEqual(view.width, 75, accuracy: 0.001)
        XCTAssertEqual(view.height, 75, accuracy: 0.001)
        let back = CropGeometry.unitRect(fromView: view, fitted: fitted)
        XCTAssertEqual(back.minX, unit.minX, accuracy: 0.0001)
        XCTAssertEqual(back.minY, unit.minY, accuracy: 0.0001)
        XCTAssertEqual(back.width, unit.width, accuracy: 0.0001)
        XCTAssertEqual(back.height, unit.height, accuracy: 0.0001)
    }

    // MARK: - Crop geometry: move / resize

    func testMoveStaysInsideBounds() {
        let bounds = CGRect(x: 75, y: 0, width: 150, height: 300)
        let box = CGRect(x: 100, y: 100, width: 50, height: 50)
        let moved = CropGeometry.move(box, by: CGSize(width: 500, height: -500), within: bounds)
        XCTAssertEqual(moved, CGRect(x: 175, y: 0, width: 50, height: 50))
        let movedBack = CropGeometry.move(box, by: CGSize(width: -500, height: 500), within: bounds)
        XCTAssertEqual(movedBack, CGRect(x: 75, y: 250, width: 50, height: 50))
    }

    func testResizeEnforcesMinimumSize() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        let shrunk = CropGeometry.resize(box, corner: .bottomRight, by: CGSize(width: -500, height: -500),
                                         within: bounds, minSize: 40)
        XCTAssertEqual(shrunk, CGRect(x: 100, y: 100, width: 40, height: 40))
        let shrunkFromTopLeft = CropGeometry.resize(box, corner: .topLeft, by: CGSize(width: 500, height: 500),
                                                    within: bounds, minSize: 40)
        XCTAssertEqual(shrunkFromTopLeft, CGRect(x: 160, y: 160, width: 40, height: 40))
    }

    func testResizeClampsToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let box = CGRect(x: 100, y: 100, width: 100, height: 100)
        let grown = CropGeometry.resize(box, corner: .bottomRight, by: CGSize(width: 1000, height: 1000),
                                        within: bounds, minSize: 40)
        XCTAssertEqual(grown, CGRect(x: 100, y: 100, width: 200, height: 200))
        let grownUp = CropGeometry.resize(box, corner: .topLeft, by: CGSize(width: -1000, height: -1000),
                                          within: bounds, minSize: 40)
        XCTAssertEqual(grownUp, CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    // MARK: - Cropping real bitmaps

    func testCropReturnsExpectedPixelSize() {
        let image = makeImage(size: CGSize(width: 200, height: 100), color: .blue)
        let cropped = CropGeometry.crop(image, unitRect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        XCTAssertNotNil(cropped)
        XCTAssertEqual(cropped?.cgImage?.width, 100)
        XCTAssertEqual(cropped?.cgImage?.height, 100)
    }

    func testNormalizedImageBakesInOrientation() throws {
        let upright = makeImage(size: CGSize(width: 100, height: 50), color: .red)
        let cgImage = try XCTUnwrap(upright.cgImage)
        let rotated = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        XCTAssertEqual(rotated.size.width, 50, accuracy: 0.001)
        let normalized = ScanImageNormalizer.normalized(rotated)
        XCTAssertEqual(normalized.imageOrientation, .up)
        XCTAssertEqual(normalized.size.width, 50, accuracy: 0.001)
        XCTAssertEqual(normalized.size.height, 100, accuracy: 0.001)
        XCTAssertEqual(normalized.cgImage?.width, 50)
        XCTAssertEqual(normalized.cgImage?.height, 100)
    }

    // MARK: - OCR reading order

    func testReadingOrderIsTopToBottomThenLeftToRight() {
        // Vision boxes: normalised, origin bottom-left, so a larger y is higher on the page.
        let lines: [TextRecognizer.RecognizedLine] = [
            TextRecognizer.RecognizedLine(text: "bottom", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
            TextRecognizer.RecognizedLine(text: "top right", box: CGRect(x: 0.6, y: 0.9, width: 0.3, height: 0.05)),
            TextRecognizer.RecognizedLine(text: "top left", box: CGRect(x: 0.1, y: 0.91, width: 0.3, height: 0.05)),
            TextRecognizer.RecognizedLine(text: "middle", box: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.05)),
        ]
        XCTAssertEqual(TextRecognizer.orderedForReading(lines), ["top left", "top right", "middle", "bottom"])
    }

    func testReadingOrderOfEmptyInputIsEmpty() {
        XCTAssertEqual(TextRecognizer.orderedForReading([]), [])
    }

    // MARK: - PDF creation and rendering

    func testPDFFromTwoImagesHasTwoPages() throws {
        let images = [
            makeImage(size: CGSize(width: 100, height: 150), color: .red),
            makeImage(size: CGSize(width: 150, height: 100), color: .blue),
        ]
        let destination = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destination) }
        try LibraryStore.writePDF(images: images, to: destination)
        XCTAssertEqual(PDFPageRenderer.pageCount(url: destination), 2)
        let document = try XCTUnwrap(PDFDocument(url: destination))
        let first = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        let second = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 100, accuracy: 0.5)
        XCTAssertEqual(first.height, 150, accuracy: 0.5)
        XCTAssertEqual(second.width, 150, accuracy: 0.5)
        XCTAssertEqual(second.height, 100, accuracy: 0.5)
    }

    func testPDFFromNoImagesThrows() {
        XCTAssertThrowsError(try LibraryStore.pdfData(images: []))
    }

    func testRenderedPageHasExpectedPixelSize() throws {
        let destination = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destination) }
        try LibraryStore.writePDF(images: [makeImage(size: CGSize(width: 100, height: 150), color: .green)],
                                  to: destination)
        let rendered = try XCTUnwrap(PDFPageRenderer.render(url: destination, pageIndex: 0, dpi: 144))
        XCTAssertEqual(rendered.cgImage?.width, 200)
        XCTAssertEqual(rendered.cgImage?.height, 300)
        XCTAssertNil(PDFPageRenderer.render(url: destination, pageIndex: 5, dpi: 72))
    }

    func testThumbnailKeepsAspectRatio() throws {
        let destination = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: destination) }
        try LibraryStore.writePDF(images: [makeImage(size: CGSize(width: 100, height: 200), color: .gray)],
                                  to: destination)
        let thumbnail = try XCTUnwrap(PDFPageRenderer.thumbnail(url: destination, pageIndex: 0, maxPixelSize: 100))
        let ratio = thumbnail.size.height / thumbnail.size.width
        XCTAssertEqual(ratio, 2, accuracy: 0.1)
    }

    func testPageCountOfMissingFileIsZero() {
        XCTAssertEqual(PDFPageRenderer.pageCount(url: temporaryFileURL()), 0)
    }

    // MARK: - Page sizing and titles

    func testPageSizeFitsLetterWithoutUpscaling() {
        let portrait = LibraryStore.pageSize(for: CGSize(width: 3000, height: 4000))
        XCTAssertEqual(portrait.width, 594, accuracy: 0.5)
        XCTAssertEqual(portrait.height, 792, accuracy: 0.5)
        let landscape = LibraryStore.pageSize(for: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(landscape.width, 792, accuracy: 0.5)
        XCTAssertEqual(landscape.height, 594, accuracy: 0.5)
        let small = LibraryStore.pageSize(for: CGSize(width: 300, height: 200))
        XCTAssertEqual(small, CGSize(width: 300, height: 200))
    }

    func testTitleFromFileName() {
        XCTAssertEqual(LibraryStore.title(fromFileName: URL(fileURLWithPath: "/tmp/my-part_v2.pdf")), "my part v2")
        XCTAssertEqual(LibraryStore.title(fromFileName: URL(fileURLWithPath: "/tmp/Scan 3.jpeg")), "Scan 3")
        XCTAssertFalse(LibraryStore.title(fromFileName: URL(fileURLWithPath: "/tmp/_.pdf")).isEmpty)
    }

    func testLooksLikePDFByExtensionOrMagicBytes() {
        let pdfMagic = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        XCTAssertTrue(LibraryStore.looksLikePDF(url: URL(fileURLWithPath: "/tmp/x.pdf"), data: Data()))
        XCTAssertTrue(LibraryStore.looksLikePDF(url: URL(fileURLWithPath: "/tmp/x.bin"), data: pdfMagic))
        XCTAssertFalse(LibraryStore.looksLikePDF(url: URL(fileURLWithPath: "/tmp/x.jpg"), data: Data([0xFF, 0xD8])))
    }

    func testLibraryErrorsHaveDescriptions() {
        let errors: [LibraryError] = [.unreadableFile, .unsupportedType, .noImages, .writeFailed]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    // MARK: - Helpers

    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scan-library-test-\(UUID().uuidString).pdf")
    }
}
