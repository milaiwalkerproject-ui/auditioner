import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// "Add from a list": camera, PDF/picture, Photos or pasted text → read on the device → review → items.
struct AuditionListImportView: View {
    let audition: Audition

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    @StateObject private var model = AuditionListImportModel()

    @State private var showingCamera: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pastedText: String = ""

    private var pool: [Excerpt] {
        catalog.excerpts(for: audition.instrument, includeDrafts: reviewerMode)
    }

    var body: some View {
        NavigationStack {
            stageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.paper.ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            DocumentCameraView(
                onFinish: { images in
                    showingCamera = false
                    model.read(images: images, pool: pool)
                },
                onCancel: {
                    showingCamera = false
                }
            )
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [UTType.pdf, UTType.image],
                      allowsMultipleSelection: false) { result in
            handleFile(result)
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            photoItems = []
            loadPhotos(newValue)
        }
    }

    // MARK: Stages

    @ViewBuilder
    private var stageContent: some View {
        switch model.stage {
        case .choose:
            chooseContent
        case .pasting:
            pasteContent
        case .loading(let message):
            ScanLoadingView(message: message)
        case .review:
            AuditionListReviewView(lines: $model.lines,
                                   instrument: audition.instrument,
                                   pool: pool,
                                   onConfirm: confirm)
        case .failed(let message):
            failedContent(message)
        }
    }

    private var chooseContent: some View {
        List {
            Section {
                Button {
                    showingCamera = true
                } label: {
                    Label("Scan with the camera", systemImage: "camera")
                }
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Choose a PDF or picture", systemImage: "folder")
                }
                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    model.startPasting()
                } label: {
                    Label("Paste the text", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("Where is the list?")
            } footer: {
                Text("The list is read on this device only. The picture is not kept and nothing is sent anywhere. You check every line before it is added.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var pasteContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste the list, one line per work. Headings like “Preliminary round” or “Solo” are understood.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            TextEditor(text: $pastedText)
                .font(.body)
                .frame(minHeight: 200)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("Back") { model.backToChoices() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    model.read(text: pastedText, pool: pool)
                } label: {
                    Label("Read the lines", systemImage: "text.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkSoft)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button("Try another way") { model.backToChoices() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private var navigationTitle: String {
        switch model.stage {
        case .choose, .loading, .failed:
            return String(localized: "Add from a list")
        case .pasting:
            return String(localized: "Paste the list")
        case .review:
            return String(localized: "Check the list")
        }
    }

    // MARK: Actions

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.stage = .failed(error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            model.read(fileURL: url, pool: pool)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        model.stage = .loading(String(localized: "Opening the photos…"))
        Task {
            var data: [Data] = []
            for item in items {
                if let loaded = try? await item.loadTransferable(type: Data.self) {
                    data.append(loaded)
                }
            }
            model.read(photoData: data, pool: pool)
        }
    }

    private func confirm() {
        let startOrder: Int = AuditionsStore.nextOrder(for: audition.id, context: modelContext)
        let items: [AuditionItem] = AuditionReviewLogic.items(from: model.lines, auditionId: audition.id, startOrder: startOrder)
        do {
            try AuditionsStore.append(items, to: audition, context: modelContext)
            dismiss()
        } catch {
            model.stage = .failed(error.localizedDescription)
        }
    }
}
