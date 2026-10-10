import Foundation
import SwiftUI
import SwiftData
import UIKit
import os

/// Where the flow is right now. Images and other working data live on `ScanFlowModel`.
enum ScanStage: Equatable {
    /// Waiting for the camera / file picker / photo picker, or loading a library item.
    case acquire
    /// Doing work; the text is shown under a spinner.
    case loading(String)
    /// A multi-page PDF or multi-page camera scan: pick the page with the excerpt.
    case pickPage
    /// Drag a box around the excerpt.
    case crop
    /// "Is this your excerpt?" (only when the flow didn't start from an excerpt page).
    case confirm
    /// First-time consent, right before the first upload.
    case consent
    /// No server address in Settings.
    case needsServer
    /// Waiting for the server.
    case recognizing
    /// Something failed; the text is the plain-words reason.
    case failed(String)
}

private let scanFlowLog = Logger(subsystem: "com.milaiwalker.auditioner", category: "ScanFlow")

/// Drives one run of scan/import → crop → identify → reference audio.
/// Every method runs on the main thread; heavy work is sent to detached tasks.
@MainActor
final class ScanFlowModel: ObservableObject {
    let context: ScanContext

    @Published var stage: ScanStage = .acquire
    /// Pages scanned with the camera when there is more than one (the user picks one).
    @Published var scannedPages: [UIImage] = []
    /// PDF the page comes from (library item, imported file).
    @Published var pdfURL: URL?
    @Published var pdfPageCount: Int = 0
    /// The whole page, upright, used for OCR and cropping.
    @Published var pageImage: UIImage?
    /// The part the user marked; this is what gets uploaded.
    @Published var croppedImage: UIImage?
    @Published var ocrLines: [String] = []
    @Published var candidates: [Excerpt] = []
    @Published var chosenExcerpt: Excerpt?

    /// Library copy made from the new scan/import, if saving worked.
    private(set) var savedLibraryItemId: UUID?

    private var catalog: CatalogStore?
    private var settings: AppSettings?
    private var router: AppRouter?
    private var modelContext: ModelContext?
    private var isConfigured = false
    private var isCancelled = false
    private var recognizeTask: Task<Void, Never>?

    init(context: ScanContext) {
        self.context = context
        self.chosenExcerpt = context.excerpt
    }

    // MARK: Setup

    /// Called once from the view's `onAppear` with the environment objects.
    func configure(catalog: CatalogStore, settings: AppSettings, router: AppRouter, modelContext: ModelContext) {
        self.catalog = catalog
        self.settings = settings
        self.router = router
        self.modelContext = modelContext
        guard !isConfigured else { return }
        isConfigured = true
        if case .libraryItem(let itemId) = context.source {
            loadLibraryItem(id: itemId)
        }
    }

    /// Stops any server call and makes sure a late answer can't open the player.
    func cancel() {
        isCancelled = true
        recognizeTask?.cancel()
        recognizeTask = nil
    }

    func closeFlow() {
        cancel()
        router?.scanContext = nil
    }

    // MARK: Acquire

    func didScanWithCamera(_ images: [UIImage]) {
        guard !images.isEmpty else {
            stage = .failed(String(localized: "No pages were scanned."))
            return
        }
        let title = ScanFlowLogic.libraryTitle(for: .camera, date: Date())
        saveToLibrary(images: images, title: title)
        if images.count == 1 {
            usePage(images[0])
        } else {
            scannedPages = images
            stage = .pickPage
        }
    }

    func didPickFile(_ url: URL) {
        stage = .loading(String(localized: "Opening the file…"))
        Task {
            // 1. Keep a copy in My parts (also gives us a plain PDF to render).
            let prepared: LibraryStore.PreparedImport? = await Task.detached(priority: .userInitiated) {
                () -> LibraryStore.PreparedImport? in
                do {
                    return try LibraryStore.prepareImport(from: url)
                } catch {
                    scanFlowLog.error("Saving the imported file to My parts failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            if self.isCancelled { return }
            if let prepared {
                if let modelContext = self.modelContext {
                    do {
                        let item = try LibraryStore.commit(prepared, title: nil, context: modelContext)
                        self.savedLibraryItemId = item.id
                        self.loadPDF(at: LibraryStore.fileURL(for: item))
                        return
                    } catch {
                        LibraryStore.discard(prepared)
                        scanFlowLog.error("Inserting the imported file into My parts failed: \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    LibraryStore.discard(prepared)
                }
            }
            // 2. Fall back to reading the file directly.
            let direct: ScanFileLoader.Loaded? = await Task.detached(priority: .userInitiated) {
                ScanFileLoader.load(url)
            }.value
            if self.isCancelled { return }
            switch direct {
            case .some(.pdf(let pdfURL)):
                self.loadPDF(at: pdfURL)
            case .some(.image(let image)):
                self.usePage(image)
            case .none:
                self.stage = .failed(String(localized: "This file couldn't be read. Try a PDF or a photo of your part."))
            }
        }
    }

    func didPickPhoto(data: Data) {
        stage = .loading(String(localized: "Opening the photo…"))
        Task {
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                UIImage(data: data).map { ScanImageNormalizer.normalized($0) }
            }.value
            if self.isCancelled { return }
            guard let image else {
                self.stage = .failed(String(localized: "This photo couldn't be read."))
                return
            }
            let title = ScanFlowLogic.libraryTitle(for: .photos, date: Date())
            self.saveToLibrary(images: [image], title: title)
            self.usePage(image)
        }
    }

    private func loadLibraryItem(id: UUID) {
        stage = .loading(String(localized: "Opening your part…"))
        guard let modelContext else {
            stage = .failed(String(localized: "This part couldn't be opened."))
            return
        }
        let descriptor = FetchDescriptor<LibraryItem>(predicate: #Predicate<LibraryItem> { $0.id == id })
        let item: LibraryItem? = (try? modelContext.fetch(descriptor))?.first
        guard let item else {
            stage = .failed(String(localized: "This part is no longer in My parts."))
            return
        }
        savedLibraryItemId = item.id
        loadPDF(at: LibraryStore.fileURL(for: item))
    }

    private func loadPDF(at url: URL) {
        stage = .loading(String(localized: "Opening the pages…"))
        Task {
            let count: Int = await Task.detached(priority: .userInitiated) {
                PDFPageRenderer.pageCount(url: url)
            }.value
            if self.isCancelled { return }
            guard count > 0 else {
                self.stage = .failed(String(localized: "This file has no pages the app can read."))
                return
            }
            self.pdfURL = url
            self.pdfPageCount = count
            if ScanFlowLogic.needsPagePicker(pageCount: count) {
                self.stage = .pickPage
            } else {
                self.choosePDFPage(0)
            }
        }
    }

    // MARK: Page choice

    func choosePDFPage(_ index: Int) {
        guard let url = pdfURL else { return }
        stage = .loading(String(localized: "Preparing the page…"))
        Task {
            let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
                PDFPageRenderer.render(url: url, pageIndex: index, dpi: 300)
            }.value
            if self.isCancelled { return }
            guard let rendered else {
                self.stage = .failed(String(localized: "This page couldn't be drawn."))
                return
            }
            self.usePage(rendered)
        }
    }

    func chooseScannedPage(_ index: Int) {
        guard index >= 0, index < scannedPages.count else { return }
        usePage(scannedPages[index])
    }

    /// Back from the page picker is not needed: the picker stays until a page is chosen.
    private func usePage(_ image: UIImage) {
        pageImage = image
        croppedImage = nil
        stage = .crop
    }

    // MARK: Crop → identify

    func didCrop(_ image: UIImage) {
        croppedImage = image
        guard let page = pageImage else {
            stage = .failed(String(localized: "The page went missing. Please start again."))
            return
        }
        stage = .loading(String(localized: "Looking at the page…"))
        Task {
            let lines: [String] = await TextRecognizer.recognizeLines(in: page)
            if self.isCancelled { return }
            self.ocrLines = lines
            if ScanFlowLogic.needsIdentification(contextExcerpt: self.context.excerpt) {
                let pool = self.identificationPool()
                self.candidates = ScanFlowLogic.candidates(ocrLines: lines, pool: pool, limit: 5)
                self.stage = .confirm
            } else {
                self.chosenExcerpt = self.context.excerpt
                self.proceedToReference()
            }
        }
    }

    /// Catalogue entries for the player's instrument (drafts only in reviewer mode).
    func identificationPool() -> [Excerpt] {
        guard let catalog, let settings else { return [] }
        return catalog.excerpts(for: settings.instrument, includeDrafts: settings.reviewerMode)
    }

    /// Text search for the confirm screen's search field.
    func searchCatalogue(_ query: String) -> [Excerpt] {
        guard let catalog, let settings else { return [] }
        return catalog.search(query, instrument: settings.instrument, includeDrafts: settings.reviewerMode)
    }

    /// From the confirm screen: the chosen excerpt, or `nil` for "It's not in the list".
    func confirmExcerpt(_ excerpt: Excerpt?) {
        chosenExcerpt = excerpt
        proceedToReference()
    }

    /// Lets the user mark the excerpt again.
    func cropAgain() {
        guard pageImage != nil else { return }
        croppedImage = nil
        stage = .crop
    }

    // MARK: Reference

    private func proceedToReference() {
        guard let settings, let router else { return }
        let serverConfigured = settings.serverBaseURL != nil
        let path = ScanFlowLogic.referencePath(excerpt: chosenExcerpt, serverConfigured: serverConfigured)
        if case .curated(let fileName) = path, let excerpt = chosenExcerpt {
            if let document = ScoreDocument.bundled(named: fileName,
                                                    title: ScanFlowLogic.scoreTitle(excerpt: excerpt, date: Date()),
                                                    origin: .curated,
                                                    instrument: excerpt.instrument,
                                                    excerptId: excerpt.id) {
                router.openPractice(document)
                return
            }
            scanFlowLog.error("Curated MusicXML \(fileName, privacy: .public) is missing from the bundle; falling back to the server.")
            handleServerPath(ScanFlowLogic.serverPath(serverConfigured: serverConfigured))
            return
        }
        handleServerPath(path)
    }

    private func handleServerPath(_ path: ScanReferencePath) {
        guard let settings else { return }
        switch path {
        case .curated:
            // Handled by the caller.
            break
        case .serverNotConfigured:
            stage = .needsServer
        case .recognizeOnServer:
            if ScanFlowLogic.needsConsent(hasAccepted: settings.hasAcceptedScanConsent, path: path) {
                stage = .consent
            } else {
                recognize()
            }
        }
    }

    func acceptConsent() {
        guard let settings else { return }
        settings.hasAcceptedScanConsent = true
        settings.objectWillChange.send()
        recognize()
    }

    func declineConsent() {
        closeFlow()
    }

    func retryRecognition() {
        recognize()
    }

    /// Sends the cropped picture to the server and saves the answer as a `ScoreRecord`.
    func recognize() {
        guard let settings, let router, let modelContext else { return }
        guard let cropped = croppedImage else {
            stage = .failed(String(localized: "The marked area went missing. Please start again."))
            return
        }
        guard let jpeg = cropped.jpegData(compressionQuality: 0.85) else {
            stage = .failed(String(localized: "The picture couldn't be prepared for upload."))
            return
        }
        let excerpt = chosenExcerpt
        let instrument = ScanFlowLogic.omrInstrument(excerpt: excerpt, settingsInstrument: settings.instrument)
        let transposition = ScanFlowLogic.transposition(excerpt: excerpt, fallbackInstrument: settings.instrument)
        let meter = ScanFlowLogic.meterHint(excerpt: excerpt)
        let hints = ocrLines
        let client = APIClient.fromSettings(settings)
        let sourceItemId = savedLibraryItemId

        stage = .recognizing
        recognizeTask?.cancel()
        recognizeTask = Task {
            do {
                let response: OMRResponse = try await client.recognize(imageJPEG: jpeg,
                                                                       instrument: instrument,
                                                                       transposition: transposition,
                                                                       meter: meter,
                                                                       hints: hints)
                if Task.isCancelled || self.isCancelled { return }
                let record = ScoreRecord(title: ScanFlowLogic.scoreTitle(excerpt: excerpt, date: Date()),
                                         musicXML: response.musicxml,
                                         origin: .omr,
                                         instrument: instrument,
                                         excerptId: excerpt?.id,
                                         sourceItemId: sourceItemId,
                                         warnings: response.warnings)
                modelContext.insert(record)
                do {
                    try modelContext.save()
                } catch {
                    scanFlowLog.error("Saving the reference failed: \(error.localizedDescription, privacy: .public)")
                }
                router.openPractice(record.document)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || self.isCancelled { return }
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Side actions

    func openExcerptPage() {
        guard let router, let excerpt = chosenExcerpt else { return }
        cancel()
        router.openedExcerptId = excerpt.id
        router.selectedTab = .excerpts
        router.scanContext = nil
    }

    func openDemo() {
        guard let router, let demo = ScoreDocument.demoScale() else { return }
        cancel()
        router.openPractice(demo)
    }

    // MARK: Library copy

    /// Keeps the new pages in My parts. Failures are logged and otherwise ignored: the scan still goes on.
    private func saveToLibrary(images: [UIImage], title: String) {
        guard let modelContext else { return }
        Task {
            let prepared: LibraryStore.PreparedImport? = await Task.detached(priority: .utility) {
                () -> LibraryStore.PreparedImport? in
                do {
                    return try LibraryStore.prepareImport(images: images, title: title)
                } catch {
                    scanFlowLog.error("Saving the scan to My parts failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            guard let prepared else { return }
            do {
                let item = try LibraryStore.commit(prepared, title: title, context: modelContext)
                if self.savedLibraryItemId == nil {
                    self.savedLibraryItemId = item.id
                }
            } catch {
                LibraryStore.discard(prepared)
                scanFlowLog.error("Inserting the scan into My parts failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Direct file reading

/// Reads a picked file without going through My parts (used when saving there failed).
enum ScanFileLoader {
    enum Loaded {
        case pdf(URL)
        case image(UIImage)
    }

    static func load(_ url: URL) -> Loaded? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if LibraryStore.looksLikePDF(url: url, data: data) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("scan-\(UUID().uuidString).pdf")
            do {
                try data.write(to: temp, options: .atomic)
            } catch {
                return nil
            }
            return .pdf(temp)
        }
        if let image = UIImage(data: data) {
            return .image(ScanImageNormalizer.normalized(image))
        }
        return nil
    }
}

// MARK: - Thumbnails

enum ScanThumbnails {
    /// A small copy of a page for the page picker (longest side `maxPixelSize`).
    static func downscaled(_ image: UIImage, maxPixelSize: CGFloat = 320) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let longest = max(size.width, size.height)
        guard longest > maxPixelSize else { return image }
        let factor = maxPixelSize / longest
        let target = CGSize(width: max(1, (size.width * factor).rounded()),
                            height: max(1, (size.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
