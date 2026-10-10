import UIKit

/// Which corner handle of the crop box is being dragged.
enum CropCorner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
}

/// Pure coordinate maths for the excerpt crop box. All functions are side-effect free so they can be unit-tested.
///
/// Three coordinate spaces:
///   * view space — points inside the crop canvas (the page is aspect-fitted and centred in it);
///   * unit space — 0…1 fractions of the fitted page (survives rotation / resizing of the canvas);
///   * pixel space — integer pixels of the underlying CGImage (image.size × image.scale).
enum CropGeometry {
    /// Smallest allowed crop box, in view points.
    static let minimumSelectionSize: CGFloat = 40

    /// Where the box starts: a band across the middle of the page.
    static let defaultUnitSelection = CGRect(x: 0.06, y: 0.25, width: 0.88, height: 0.5)

    /// The rectangle an aspect-fitted image occupies inside `container` (centred, letterboxed).
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Unit rect (fractions of the fitted page) → view points.
    static func viewRect(fromUnit unit: CGRect, fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + unit.minX * fitted.width,
               y: fitted.minY + unit.minY * fitted.height,
               width: unit.width * fitted.width,
               height: unit.height * fitted.height)
    }

    /// View points → unit rect, clamped to 0…1.
    static func unitRect(fromView view: CGRect, fitted: CGRect) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return defaultUnitSelection }
        let clipped = view.intersection(fitted)
        guard !clipped.isNull, !clipped.isEmpty else { return defaultUnitSelection }
        return CGRect(x: (clipped.minX - fitted.minX) / fitted.width,
                      y: (clipped.minY - fitted.minY) / fitted.height,
                      width: clipped.width / fitted.width,
                      height: clipped.height / fitted.height)
    }

    /// View points → image points (UIImage.size space), clamped to the image.
    static func imagePointRect(fromViewRect view: CGRect, fitted: CGRect, imageSize: CGSize) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        let clipped = view.intersection(fitted)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let ratioX = imageSize.width / fitted.width
        let ratioY = imageSize.height / fitted.height
        return CGRect(x: (clipped.minX - fitted.minX) * ratioX,
                      y: (clipped.minY - fitted.minY) * ratioY,
                      width: clipped.width * ratioX,
                      height: clipped.height * ratioY)
    }

    /// View points → whole pixels of the CGImage behind a UIImage of `imageSize` points at `scale`.
    /// Edges are rounded to the nearest pixel and the result is clamped to the bitmap.
    static func pixelRect(fromViewRect view: CGRect, fitted: CGRect, imageSize: CGSize, scale: CGFloat) -> CGRect {
        let points = imagePointRect(fromViewRect: view, fitted: fitted, imageSize: imageSize)
        guard !points.isEmpty, scale > 0 else { return .zero }
        let pixelWidth = (imageSize.width * scale).rounded()
        let pixelHeight = (imageSize.height * scale).rounded()
        var minX = (points.minX * scale).rounded()
        var minY = (points.minY * scale).rounded()
        var maxX = (points.maxX * scale).rounded()
        var maxY = (points.maxY * scale).rounded()
        minX = min(max(minX, 0), pixelWidth)
        maxX = min(max(maxX, 0), pixelWidth)
        minY = min(max(minY, 0), pixelHeight)
        maxY = min(max(maxY, 0), pixelHeight)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves a box by a drag translation, keeping it inside `bounds`.
    static func move(_ rect: CGRect, by translation: CGSize, within bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: translation.width, dy: translation.height)
        if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
        if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
        if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
        if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
        return moved
    }

    /// Resizes a box by dragging one corner, keeping it inside `bounds` and at least `minSize` on each side.
    static func resize(_ rect: CGRect, corner: CropCorner, by translation: CGSize,
                       within bounds: CGRect, minSize: CGFloat) -> CGRect {
        let effectiveMin = max(1, min(minSize, bounds.width, bounds.height))
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch corner {
        case .topLeft:
            minX += translation.width
            minY += translation.height
        case .topRight:
            maxX += translation.width
            minY += translation.height
        case .bottomLeft:
            minX += translation.width
            maxY += translation.height
        case .bottomRight:
            maxX += translation.width
            maxY += translation.height
        }
        minX = max(bounds.minX, minX)
        maxX = min(bounds.maxX, maxX)
        minY = max(bounds.minY, minY)
        maxY = min(bounds.maxY, maxY)
        if maxX - minX < effectiveMin {
            switch corner {
            case .topLeft, .bottomLeft: minX = maxX - effectiveMin
            case .topRight, .bottomRight: maxX = minX + effectiveMin
            }
        }
        if maxY - minY < effectiveMin {
            switch corner {
            case .topLeft, .topRight: minY = maxY - effectiveMin
            case .bottomLeft, .bottomRight: maxY = minY + effectiveMin
            }
        }
        let result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let clamped = result.intersection(bounds)
        if clamped.isNull || clamped.isEmpty { return result }
        return clamped
    }

    /// The view-space position of a corner handle.
    static func point(of corner: CropCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Crops an upright (`.up`) image to a unit rect. Returns nil when the area is empty or the image has no bitmap.
    static func crop(_ image: UIImage, unitRect: CGRect) -> UIImage? {
        let upright = ScanImageNormalizer.normalized(image)
        guard let cgImage = upright.cgImage else { return nil }
        let full = CGRect(origin: .zero, size: upright.size)
        let view = viewRect(fromUnit: unitRect, fitted: full)
        let pixels = pixelRect(fromViewRect: view, fitted: full, imageSize: upright.size, scale: upright.scale)
        guard !pixels.isEmpty else { return nil }
        guard let cropped = cgImage.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped, scale: upright.scale, orientation: .up)
    }
}
