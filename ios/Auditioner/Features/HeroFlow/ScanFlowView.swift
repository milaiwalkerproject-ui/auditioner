import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Scan/import → crop → identify → reference audio.
///
/// Presented full screen by `RootView` whenever `AppRouter.scanContext` is set. One `NavigationStack`
/// whose content swaps with `ScanFlowModel.stage`; a Cancel button closes the flow from any step.
struct ScanFlowView: View {
    let context: ScanContext

    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext

    @StateObject private var model: ScanFlowModel

    @State private var showingFileImporter: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var pickerShownOnce: Bool = false

    init(context: ScanContext) {
        self.context = context
        _model = StateObject(wrappedValue: ScanFlowModel(context: context))
    }

    var body: some View {
        NavigationStack {
            stageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.paper.ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(hidesNavigationBar ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            closeFlow()
                        }
                    }
                }
        }
        .onAppear {
            model.configure(catalog: catalog, settings: settings, router: router, modelContext: modelContext)
            presentPickerIfNeeded()
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [UTType.pdf, UTType.image],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let item = newValue else { return }
            photoItem = nil
            loadPhoto(item)
        }
    }

    // MARK: Stage content

    @ViewBuilder
    private var stageContent: some View {
        switch model.stage {
        case .acquire:
            acquireContent
        case .loading(let message):
            ScanLoadingView(message: message)
        case .pickPage:
            pagePicker
        case .crop:
            cropContent
        case .confirm:
            ScanConfirmView(model: model)
        case .consent:
            ScanConsentView(onAgree: { model.acceptConsent() },
                            onNotNow: { model.declineConsent() })
        case .needsServer:
            ScanNeedsServerView(hasExcerpt: model.chosenExcerpt != nil,
                                onOpenExcerpt: { model.openExcerptPage() },
                                onTryDemo: { model.openDemo() },
                                onClose: { closeFlow() })
        case .recognizing:
            ScanRecognizingView()
        case .failed(let message):
            ScanFailedView(message: message,
                           canRetry: model.croppedImage != nil,
                           onRetry: { model.retryRecognition() },
                           onClose: { closeFlow() })
        }
    }

    @ViewBuilder
    private var acquireContent: some View {
        switch context.source {
        case .camera:
            DocumentCameraView(
                onFinish: { images in
                    model.didScanWithCamera(images)
                },
                onCancel: {
                    closeFlow()
                }
            )
        case .files:
            ScanPickerPlaceholder(
                symbol: "folder",
                title: String(localized: "Choose a PDF or a picture of your part"),
                buttonTitle: String(localized: "Choose a file"),
                action: { showingFileImporter = true }
            )
        case .photos:
            ScanPickerPlaceholder(
                symbol: "photo.on.rectangle",
                title: String(localized: "Choose a photo of your part"),
                buttonTitle: String(localized: "Choose a photo"),
                action: { showingPhotoPicker = true }
            )
        case .libraryItem:
            ScanLoadingView(message: String(localized: "Opening your part…"))
        }
    }

    @ViewBuilder
    private var pagePicker: some View {
        if let url = model.pdfURL, model.pdfPageCount > 0 {
            ScanPDFPagePicker(url: url, pageCount: model.pdfPageCount) { index in
                model.choosePDFPage(index)
            }
        } else {
            ScanImagePagePicker(pages: model.scannedPages) { index in
                model.chooseScannedPage(index)
            }
        }
    }

    @ViewBuilder
    private var cropContent: some View {
        if let page = model.pageImage {
            ExcerptCropView(
                image: page,
                onCrop: { cropped in
                    model.didCrop(cropped)
                },
                onCancel: {
                    closeFlow()
                }
            )
        } else {
            ScanFailedView(message: String(localized: "The page went missing. Please start again."),
                           canRetry: false,
                           onRetry: {},
                           onClose: { closeFlow() })
        }
    }

    // MARK: Chrome

    private var navigationTitle: String {
        switch model.stage {
        case .acquire, .loading:
            return String(localized: "Scan my part")
        case .pickPage:
            return String(localized: "Choose a page")
        case .crop:
            return String(localized: "Mark the excerpt")
        case .confirm:
            return String(localized: "Is this your excerpt?")
        case .consent:
            return String(localized: "Before your first scan")
        case .needsServer:
            return String(localized: "Reference audio")
        case .recognizing:
            return String(localized: "Reading the notes")
        case .failed:
            return String(localized: "Something went wrong")
        }
    }

    /// The system camera and the crop screen bring their own Cancel buttons.
    private var hidesNavigationBar: Bool {
        switch model.stage {
        case .acquire:
            if case .camera = context.source { return true }
            return false
        case .crop:
            return true
        default:
            return false
        }
    }

    // MARK: Actions

    private func closeFlow() {
        model.cancel()
        router.scanContext = nil
    }

    private func presentPickerIfNeeded() {
        guard !pickerShownOnce else { return }
        pickerShownOnce = true
        switch context.source {
        case .files:
            showingFileImporter = true
        case .photos:
            showingPhotoPicker = true
        case .camera, .libraryItem:
            break
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.stage = .failed(error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            model.didPickFile(url)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        model.stage = .loading(String(localized: "Opening the photo…"))
        Task {
            let data: Data? = try? await item.loadTransferable(type: Data.self)
            guard let data else {
                model.stage = .failed(String(localized: "This photo couldn't be read."))
                return
            }
            model.didPickPhoto(data: data)
        }
    }
}

// MARK: - Placeholder while a system picker is up

private struct ScanPickerPlaceholder: View {
    let symbol: String
    let title: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkSoft)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
