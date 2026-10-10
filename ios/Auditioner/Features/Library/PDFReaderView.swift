import SwiftUI
import SwiftData
import UIKit
import PDFKit
import PencilKit

// Simple reader (PLAN P5): open a PDF, turn pages by swipe, tap zones or a Bluetooth pedal
// (AirTurn and friends send arrow / page keys / space), draw on pages with Apple Pencil.

// MARK: - SwiftUI entry point

/// Full-page reader for one library item, with page indicator, Markup toggle and Done.
struct PDFReaderView: View {
    let item: LibraryItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PDFReaderModel()

    init(item: LibraryItem) {
        self.item = item
    }

    var body: some View {
        PDFReaderRepresentable(item: item, model: model, modelContext: modelContext)
            .ignoresSafeArea(edges: .bottom)
            .background(Color.white)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(model.barsHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        model.isMarkupOn = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    pageIndicator
                }
                ToolbarItem(placement: .topBarTrailing) {
                    markupToggle
                }
            }
            .onDisappear {
                try? modelContext.save()
            }
    }

    private var pageIndicator: some View {
        Text("Page \(model.currentPage + 1) of \(max(model.pageCount, 1))")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.inkSoft)
            .monospacedDigit()
    }

    private var markupToggle: some View {
        Toggle(isOn: $model.isMarkupOn) {
            Label("Markup", systemImage: "pencil.tip.crop.circle")
        }
        .toggleStyle(.button)
        .accessibilityLabel(Text("Markup"))
    }
}

/// Shared state between the SwiftUI toolbar and the UIKit controller.
final class PDFReaderModel: ObservableObject {
    @Published var currentPage: Int = 0
    @Published var pageCount: Int = 0
    @Published var isMarkupOn: Bool = false
    @Published var barsHidden: Bool = false
}

// MARK: - Representable

struct PDFReaderRepresentable: UIViewControllerRepresentable {
    let item: LibraryItem
    let model: PDFReaderModel
    let modelContext: ModelContext

    func makeUIViewController(context: Context) -> PDFReaderController {
        let controller = PDFReaderController(itemId: item.id,
                                             fileURL: LibraryStore.fileURL(for: item),
                                             initialPage: item.lastOpenedPage,
                                             modelContext: modelContext)
        let model = self.model
        let item = self.item
        controller.onPageChanged = { pageIndex, pageCount in
            model.currentPage = pageIndex
            model.pageCount = pageCount
            if item.lastOpenedPage != pageIndex {
                item.lastOpenedPage = pageIndex
            }
        }
        controller.onCenterTap = {
            model.barsHidden.toggle()
        }
        return controller
    }

    func updateUIViewController(_ controller: PDFReaderController, context: Context) {
        controller.setMarkupEnabled(model.isMarkupOn)
    }
}

// MARK: - Controller

/// PDFView in single-page, horizontal, page-view-controller mode with PencilKit overlays per page.
final class PDFReaderController: UIViewController {
    let itemId: UUID
    let fileURL: URL
    let modelContext: ModelContext

    /// (page index, page count) — delivered on the main queue, never during a layout pass.
    var onPageChanged: ((Int, Int) -> Void)?
    /// Tap in the middle third of the page.
    var onCenterTap: (() -> Void)?

    private let pdfView = PDFView()
    private let missingLabel = UILabel()
    private let toolPicker = PKToolPicker()
    private var initialPage: Int
    private var hasRestoredInitialPage = false
    private(set) var isMarkupEnabled = false
    /// Live overlay canvases keyed by page index (removed when PDFKit stops displaying the page).
    private var canvases: [Int: PageCanvasView] = [:]
    private var pendingSaves: [Int: DispatchWorkItem] = [:]

    init(itemId: UUID, fileURL: URL, initialPage: Int, modelContext: ModelContext) {
        self.itemId = itemId
        self.fileURL = fileURL
        self.initialPage = initialPage
        self.modelContext = modelContext
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        pdfView.backgroundColor = .white
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = false
        pdfView.pageOverlayViewProvider = self
        pdfView.isInMarkupMode = false

        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.text = String(localized: "This part's file is missing. Delete it and add it again.")
        missingLabel.textColor = .secondaryLabel
        missingLabel.font = UIFont.preferredFont(forTextStyle: .body)
        missingLabel.textAlignment = .center
        missingLabel.numberOfLines = 0
        missingLabel.isHidden = true
        view.addSubview(missingLabel)
        NSLayoutConstraint.activate([
            missingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            missingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            missingLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange(_:)),
                                               name: Notification.Name.PDFViewPageChanged, object: pdfView)

        if let document = PDFDocument(url: fileURL), document.pageCount > 0 {
            pdfView.document = document
            restoreInitialPageIfNeeded()
        } else {
            missingLabel.isHidden = false
            pdfView.isHidden = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        restoreInitialPageIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isMarkupEnabled {
            becomeFirstResponder()
        }
        notifyPageChanged()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveAllCanvases()
        hideToolPicker()
        try? modelContext.save()
    }

    private func restoreInitialPageIfNeeded() {
        guard !hasRestoredInitialPage, let document = pdfView.document, document.pageCount > 0 else { return }
        guard pdfView.bounds.width > 0 else { return }
        hasRestoredInitialPage = true
        let index = min(max(initialPage, 0), document.pageCount - 1)
        if index > 0, let page = document.page(at: index) {
            pdfView.go(to: page)
        }
        notifyPageChanged()
    }

    // MARK: Pages

    var currentPageIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        let index = document.index(for: page)
        return index == NSNotFound ? 0 : index
    }

    var pageCount: Int {
        pdfView.document?.pageCount ?? 0
    }

    @objc private func pageDidChange(_ notification: Notification) {
        notifyPageChanged()
        if isMarkupEnabled {
            showToolPickerForVisibleCanvas()
        }
    }

    private func notifyPageChanged() {
        let index = currentPageIndex
        let count = pageCount
        DispatchQueue.main.async { [weak self] in
            self?.onPageChanged?(index, count)
        }
    }

    @objc func goToNextPage() {
        if pdfView.canGoToNextPage {
            pdfView.goToNextPage(nil)
        }
    }

    @objc func goToPreviousPage() {
        if pdfView.canGoToPreviousPage {
            pdfView.goToPreviousPage(nil)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: pdfView)
        let width = pdfView.bounds.width
        guard width > 0 else { return }
        if isMarkupEnabled {
            return
        }
        if location.x < width / 3 {
            goToPreviousPage()
        } else if location.x > width * 2 / 3 {
            goToNextPage()
        } else {
            onCenterTap?()
        }
    }

    // MARK: Hardware keys (AirTurn and other Bluetooth pedals)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let nextInputs: [String] = [UIKeyCommand.inputRightArrow, UIKeyCommand.inputDownArrow,
                                    UIKeyCommand.inputPageDown, " "]
        let previousInputs: [String] = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputUpArrow,
                                        UIKeyCommand.inputPageUp]
        var commands: [UIKeyCommand] = []
        for input in nextInputs {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(goToNextPage))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        for input in previousInputs {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(goToPreviousPage))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    // MARK: Markup

    func setMarkupEnabled(_ enabled: Bool) {
        guard enabled != isMarkupEnabled else { return }
        isMarkupEnabled = enabled
        pdfView.isInMarkupMode = enabled
        for canvas in canvases.values {
            canvas.isUserInteractionEnabled = enabled
        }
        if enabled {
            showToolPickerForVisibleCanvas()
        } else {
            hideToolPicker()
            saveAllCanvases()
            becomeFirstResponder()
        }
    }

    private func visibleCanvas() -> PageCanvasView? {
        canvases[currentPageIndex]
    }

    private func showToolPickerForVisibleCanvas() {
        guard let canvas = visibleCanvas() else { return }
        for other in canvases.values where other !== canvas {
            toolPicker.setVisible(false, forFirstResponder: other)
        }
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        canvas.becomeFirstResponder()
    }

    private func hideToolPicker() {
        for canvas in canvases.values {
            toolPicker.setVisible(false, forFirstResponder: canvas)
            toolPicker.removeObserver(canvas)
            if canvas.isFirstResponder {
                canvas.resignFirstResponder()
            }
        }
    }

    private func makeCanvas(for pageIndex: Int) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.pageIndex = pageIndex
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .red, width: 3)
        canvas.isUserInteractionEnabled = isMarkupEnabled
        canvas.delegate = self
        if let data = loadDrawingData(pageIndex: pageIndex), let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }
        return canvas
    }

    // MARK: Persistence

    private func fetchAnnotation(pageIndex: Int) -> PageAnnotation? {
        let itemId = self.itemId
        let index = pageIndex
        var descriptor = FetchDescriptor<PageAnnotation>(
            predicate: #Predicate<PageAnnotation> { $0.itemId == itemId && $0.pageIndex == index }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func loadDrawingData(pageIndex: Int) -> Data? {
        guard let annotation = fetchAnnotation(pageIndex: pageIndex), !annotation.drawingData.isEmpty else {
            return nil
        }
        return annotation.drawingData
    }

    /// Upserts the PageAnnotation for one page.
    private func saveDrawing(_ drawing: PKDrawing, pageIndex: Int) {
        let data = drawing.strokes.isEmpty ? Data() : drawing.dataRepresentation()
        if let existing = fetchAnnotation(pageIndex: pageIndex) {
            if existing.drawingData != data {
                existing.drawingData = data
                existing.updatedAt = Date()
            }
        } else {
            guard !data.isEmpty else { return }
            let annotation = PageAnnotation(itemId: itemId, pageIndex: pageIndex, drawingData: data)
            modelContext.insert(annotation)
        }
        try? modelContext.save()
    }

    private func scheduleSave(for canvas: PageCanvasView) {
        let index = canvas.pageIndex
        pendingSaves[index]?.cancel()
        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.pendingSaves[index] = nil
            self.saveDrawing(canvas.drawing, pageIndex: index)
        }
        pendingSaves[index] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveAllCanvases() {
        for (index, work) in pendingSaves {
            work.cancel()
            pendingSaves[index] = nil
        }
        for (index, canvas) in canvases {
            saveDrawing(canvas.drawing, pageIndex: index)
        }
    }
}

// MARK: - Overlay provider (PencilKit canvas per page)

extension PDFReaderController: PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0 else { return nil }
        if let existing = canvases[index] {
            return existing
        }
        let canvas = makeCanvas(for: index)
        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        overlayView.isUserInteractionEnabled = isMarkupEnabled
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PageCanvasView else { return }
        let index = canvas.pageIndex
        pendingSaves[index]?.cancel()
        pendingSaves[index] = nil
        saveDrawing(canvas.drawing, pageIndex: index)
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.removeObserver(canvas)
        if canvases[index] === canvas {
            canvases[index] = nil
        }
    }
}

// MARK: - PencilKit delegate

extension PDFReaderController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? PageCanvasView else { return }
        scheduleSave(for: canvas)
    }
}

// MARK: - Gesture delegate

extension PDFReaderController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type != .pencil
    }
}

// MARK: - Canvas

/// PKCanvasView that remembers which page it belongs to.
final class PageCanvasView: PKCanvasView {
    var pageIndex: Int = 0
}
