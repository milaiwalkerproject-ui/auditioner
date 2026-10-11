import SwiftUI
import UIKit

/// A picture that fits its frame and can be pinched to zoom and dragged (double-tap zooms in and out).
struct ZoomableImageView: UIViewRepresentable {
    var image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView(frame: .zero)
        view.image = image
        return view
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        if uiView.image !== image {
            uiView.image = image
        }
    }
}

/// UIScrollView that hosts one UIImageView, keeps it centred and fits it on first layout.
final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedBoundsSize: CGSize = .zero

    var image: UIImage? {
        didSet {
            imageView.image = image
            let size = image?.size ?? .zero
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            fittedBoundsSize = .zero
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = UIColor.clear
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBoundsSize, bounds.width > 0, bounds.height > 0 {
            fittedBoundsSize = bounds.size
            fitImage()
        }
        centerImage()
    }

    private func fitImage() {
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 8, 1)
        zoomScale = fit
    }

    private func centerImage() {
        let frame = imageView.frame
        let dx = max(0, (bounds.width - frame.width) / 2)
        let dy = max(0, (bounds.height - frame.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let target: CGFloat = zoomScale > minimumZoomScale * 1.01 ? minimumZoomScale : min(maximumZoomScale, minimumZoomScale * 2.5)
        if target <= minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let width = bounds.width / target
        let height = bounds.height / target
        let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        zoom(to: rect, animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}
