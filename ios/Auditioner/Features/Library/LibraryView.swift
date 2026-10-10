import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// CONTRACT (owner: library agent): the user's imported parts.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \LibraryItem.createdAt, order: .reverse) private var items: [LibraryItem]

    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var errorMessage: String? = nil
    @State private var renamingItem: LibraryItem? = nil
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("My parts")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        addMenu
                    }
                }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            DocumentCameraView(
                onFinish: { images in
                    showingCamera = false
                    importScannedImages(images)
                },
                onCancel: {
                    showingCamera = false
                }
            )
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [UTType.pdf, UTType.image],
                      allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoSelection,
                      maxSelectionCount: 20, matching: .images)
        .onChange(of: photoSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            photoSelection = []
            importPhotos(newValue)
        }
        .alert("Couldn't add this part", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename part", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renamingItem = nil }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            if items.isEmpty {
                LibraryEmptyState(addMenu: addMenu)
            } else {
                list
            }
            if isImporting {
                importingOverlay
            }
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                NavigationLink {
                    PDFReaderView(item: item)
                } label: {
                    LibraryRow(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        router.startScan(.libraryItem(item.id))
                    } label: {
                        Label("Make reference audio", systemImage: "waveform")
                    }
                    Button {
                        renameText = item.title
                        renamingItem = item
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var importingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Adding your part…")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    private var addMenu: some View {
        Menu {
            Button {
                showingCamera = true
            } label: {
                Label("Scan with camera", systemImage: "camera")
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("Import from Files", systemImage: "folder")
            }
            Button {
                showingPhotoPicker = true
            } label: {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
        } label: {
            Label("Add part", systemImage: "plus")
        }
    }

    // MARK: Bindings

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in if !newValue { errorMessage = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { newValue in if !newValue { renamingItem = nil } }
        )
    }

    // MARK: Actions

    private func commitRename() {
        guard let item = renamingItem else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            item.title = trimmed
            try? modelContext.save()
        }
        renamingItem = nil
    }

    private func delete(_ item: LibraryItem) {
        LibraryThumbnailCache.shared.remove(item.fileName)
        LibraryStore.delete(item, context: modelContext)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            runImport { () throws -> [LibraryStore.PreparedImport] in
                var prepared: [LibraryStore.PreparedImport] = []
                var firstError: Error? = nil
                for url in urls {
                    do {
                        prepared.append(try LibraryStore.prepareImport(from: url))
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
                if prepared.isEmpty, let firstError {
                    throw firstError
                }
                return prepared
            }
        }
    }

    private func importScannedImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let title = String(localized: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))")
        runImport { () throws -> [LibraryStore.PreparedImport] in
            [try LibraryStore.prepareImport(images: images, title: title)]
        }
    }

    private func importPhotos(_ pickerItems: [PhotosPickerItem]) {
        let title = String(localized: "Photos \(Date().formatted(date: .abbreviated, time: .shortened))")
        let context = modelContext
        isImporting = true
        Task {
            var images: [UIImage] = []
            for pickerItem in pickerItems {
                if let data = try? await pickerItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            let loaded = images
            let outcome: Result<[LibraryStore.PreparedImport], Error> = await Task.detached(priority: .userInitiated) {
                () -> Result<[LibraryStore.PreparedImport], Error> in
                do {
                    return .success([try LibraryStore.prepareImport(images: loaded, title: title)])
                } catch {
                    return .failure(error)
                }
            }.value
            await finishImport(outcome, context: context)
        }
    }

    /// Runs the file work off the main thread, then inserts the items on the main thread.
    private func runImport(_ work: @escaping () throws -> [LibraryStore.PreparedImport]) {
        let context = modelContext
        isImporting = true
        Task {
            let outcome: Result<[LibraryStore.PreparedImport], Error> = await Task.detached(priority: .userInitiated) {
                () -> Result<[LibraryStore.PreparedImport], Error> in
                do {
                    return .success(try work())
                } catch {
                    return .failure(error)
                }
            }.value
            await finishImport(outcome, context: context)
        }
    }

    @MainActor
    private func finishImport(_ outcome: Result<[LibraryStore.PreparedImport], Error>, context: ModelContext) {
        isImporting = false
        switch outcome {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let prepared):
            for entry in prepared {
                do {
                    try LibraryStore.commit(entry, title: nil, context: context)
                } catch {
                    LibraryStore.discard(entry)
                    if errorMessage == nil { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

// MARK: - Row

private struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumbnailView(fileName: item.fileName)
                .frame(width: 48, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Text("·")
                    pageCountText
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var pageCountText: Text {
        if item.pageCount == 1 {
            return Text("1 page")
        }
        return Text("\(item.pageCount) pages")
    }
}

/// First-page preview, rendered once per file and kept in memory.
private struct LibraryThumbnailView: View {
    let fileName: String
    @State private var image: UIImage? = nil

    init(fileName: String) {
        self.fileName = fileName
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: fileName) {
            await load()
        }
    }

    private func load() async {
        if let cached = LibraryThumbnailCache.shared.image(for: fileName) {
            image = cached
            return
        }
        let url = LibraryStore.directory.appendingPathComponent(fileName)
        let key = fileName
        let rendered: UIImage? = await Task.detached(priority: .utility) {
            PDFPageRenderer.thumbnail(url: url, pageIndex: 0, maxPixelSize: 200)
        }.value
        if let rendered {
            LibraryThumbnailCache.shared.set(rendered, for: key)
            if key == fileName {
                image = rendered
            }
        }
    }
}

final class LibraryThumbnailCache {
    static let shared = LibraryThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
    }
}

// MARK: - Empty state

private struct LibraryEmptyState<AddMenu: View>: View {
    let addMenu: AddMenu

    var body: some View {
        ContentUnavailableView {
            Label("No parts yet", systemImage: "doc.richtext")
        } description: {
            Text("Add a PDF from Files (including iCloud Drive, Google Drive and Dropbox), a photo from Photos, or scan a page with the camera. Your parts stay on this device.")
        } actions: {
            addMenu
                .buttonStyle(.borderedProminent)
        }
    }
}
