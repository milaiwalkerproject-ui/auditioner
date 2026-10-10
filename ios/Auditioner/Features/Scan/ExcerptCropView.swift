import SwiftUI
import UIKit

/// Lets the user drag a box around the excerpt on a page image.
/// Drag inside the box to move it, drag a corner to resize it. "Use whole page" skips cropping.
struct ExcerptCropView: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void
    var onCancel: () -> Void

    /// The page redrawn upright (orientation baked in) so pixel maths is straightforward.
    @State private var page: UIImage? = nil
    /// Current selection as fractions (0…1) of the page.
    @State private var selection: CGRect = CropGeometry.defaultUnitSelection

    init(image: UIImage, onCrop: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onCrop = onCrop
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
            buttons
        }
        .background(Theme.paper.ignoresSafeArea())
        .onAppear {
            if page == nil {
                page = ScanImageNormalizer.normalized(image)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Mark the excerpt")
                .font(Theme.displayFont(.title3))
                .foregroundStyle(Theme.ink)
            Text("Drag the box around the bars you want. Drag a corner to resize it.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            if let page {
                CropCanvas(image: page, containerSize: geometry.size, selection: $selection)
            } else {
                ProgressView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .padding(.horizontal, 12)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            Spacer()
            Button("Use whole page") {
                onCrop(page ?? image)
            }
            .buttonStyle(.bordered)
            Button("Use this area") {
                useSelectedArea()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func useSelectedArea() {
        let upright = page ?? ScanImageNormalizer.normalized(image)
        if let cropped = CropGeometry.crop(upright, unitRect: selection) {
            onCrop(cropped)
        } else {
            onCrop(upright)
        }
    }
}

// MARK: - Canvas

/// The page with the dimmed surround, the selection frame and its four handles.
private struct CropCanvas: View {
    let image: UIImage
    let containerSize: CGSize
    @Binding var selection: CGRect

    /// View-space box at the start of the current drag (DragGesture translations are cumulative).
    @State private var dragStart: CGRect? = nil

    init(image: UIImage, containerSize: CGSize, selection: Binding<CGRect>) {
        self.image = image
        self.containerSize = containerSize
        self._selection = selection
    }

    private var fitted: CGRect {
        CropGeometry.fittedRect(imageSize: image.size, in: containerSize)
    }

    private var viewRect: CGRect {
        CropGeometry.viewRect(fromUnit: selection, fitted: fitted)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: containerSize.width, height: containerSize.height)
            CropDimming(fitted: fitted, selection: viewRect)
                .allowsHitTesting(false)
            selectionFrame
            handle(for: .topLeft)
            handle(for: .topRight)
            handle(for: .bottomLeft)
            handle(for: .bottomRight)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
    }

    private var selectionFrame: some View {
        let rect = viewRect
        return Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .position(x: rect.midX, y: rect.midY)
    }

    private func handle(for corner: CropCorner) -> some View {
        let point = CropGeometry.point(of: corner, in: viewRect)
        return CropHandle()
            .gesture(resizeGesture(corner))
            .position(x: point.x, y: point.y)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start: CGRect
                if let existing = dragStart {
                    start = existing
                } else {
                    start = viewRect
                    dragStart = start
                }
                let moved = CropGeometry.move(start, by: value.translation, within: fitted)
                selection = CropGeometry.unitRect(fromView: moved, fitted: fitted)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private func resizeGesture(_ corner: CropCorner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start: CGRect
                if let existing = dragStart {
                    start = existing
                } else {
                    start = viewRect
                    dragStart = start
                }
                let resized = CropGeometry.resize(start, corner: corner, by: value.translation,
                                                  within: fitted, minSize: CropGeometry.minimumSelectionSize)
                selection = CropGeometry.unitRect(fromView: resized, fitted: fitted)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

/// Darkens everything on the page outside the selection.
private struct CropDimming: View {
    let fitted: CGRect
    let selection: CGRect

    var body: some View {
        Path { path in
            let top = CGRect(x: fitted.minX, y: fitted.minY,
                             width: fitted.width, height: max(0, selection.minY - fitted.minY))
            let bottom = CGRect(x: fitted.minX, y: selection.maxY,
                                width: fitted.width, height: max(0, fitted.maxY - selection.maxY))
            let left = CGRect(x: fitted.minX, y: selection.minY,
                              width: max(0, selection.minX - fitted.minX), height: selection.height)
            let right = CGRect(x: selection.maxX, y: selection.minY,
                               width: max(0, fitted.maxX - selection.maxX), height: selection.height)
            path.addRect(top)
            path.addRect(bottom)
            path.addRect(left)
            path.addRect(right)
        }
        .fill(Color.black.opacity(0.45))
    }
}

/// A corner handle with a generous 44pt hit area.
private struct CropHandle: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Theme.garnet, lineWidth: 2))
            .frame(width: 20, height: 20)
            .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
