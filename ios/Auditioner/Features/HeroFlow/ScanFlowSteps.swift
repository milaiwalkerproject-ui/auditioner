import SwiftUI
import UIKit

// Step screens of the scan flow. Each is small and takes plain values or closures,
// so `ScanFlowView` stays easy for the type-checker.

// MARK: - Loading

struct ScanLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Page pickers

/// Thumbnails of every page of a PDF; tap one to use it.
struct ScanPDFPagePicker: View {
    let url: URL
    let pageCount: Int
    let onChoose: (Int) -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Which page has the excerpt?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button {
                            onChoose(index)
                        } label: {
                            ScanPageCell(label: pageLabel(index)) {
                                ScanPDFThumbnail(url: url, pageIndex: index)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func pageLabel(_ index: Int) -> String {
        String(localized: "Page \(index + 1)")
    }
}

/// Thumbnails of pages scanned with the camera; tap one to use it.
struct ScanImagePagePicker: View {
    let pages: [UIImage]
    let onChoose: (Int) -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Which page has the excerpt?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Button {
                            onChoose(index)
                        } label: {
                            ScanPageCell(label: pageLabel(index)) {
                                ScanImageThumbnail(image: pages[index])
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private func pageLabel(_ index: Int) -> String {
        String(localized: "Page \(index + 1)")
    }
}

/// A framed thumbnail with a caption.
struct ScanPageCell<Thumbnail: View>: View {
    let label: String
    let thumbnail: () -> Thumbnail

    init(label: String, @ViewBuilder thumbnail: @escaping () -> Thumbnail) {
        self.label = label
        self.thumbnail = thumbnail
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white)
                thumbnail()
                    .padding(4)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

/// Renders one PDF page at 72 dpi, off the main thread.
struct ScanPDFThumbnail: View {
    let url: URL
    let pageIndex: Int
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: pageIndex) {
            let url = self.url
            let index = self.pageIndex
            let rendered: UIImage? = await Task.detached(priority: .utility) {
                PDFPageRenderer.render(url: url, pageIndex: index, dpi: 72)
            }.value
            image = rendered
        }
    }
}

/// A downscaled copy of a camera page, made off the main thread.
struct ScanImageThumbnail: View {
    let image: UIImage
    @State private var small: UIImage? = nil

    var body: some View {
        Group {
            if let small {
                Image(uiImage: small)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task {
            let source = self.image
            let rendered: UIImage = await Task.detached(priority: .utility) {
                ScanThumbnails.downscaled(source, maxPixelSize: 320)
            }.value
            small = rendered
        }
    }
}

// MARK: - Confirm the excerpt

/// "Is this your excerpt?" — best matches from the page's text, a search field, and a way out.
struct ScanConfirmView: View {
    @ObservedObject var model: ScanFlowModel
    @State private var query: String = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [Excerpt] {
        guard !trimmedQuery.isEmpty else { return [] }
        return Array(model.searchCatalogue(trimmedQuery).prefix(25))
    }

    var body: some View {
        List {
            if let cropped = model.croppedImage {
                previewSection(cropped)
            }
            matchesSection
            searchSection
            otherwiseSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func previewSection(_ cropped: UIImage) -> some View {
        Section {
            Image(uiImage: cropped)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 160)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    private var matchesSection: some View {
        Section {
            if model.candidates.isEmpty {
                Text("The text on this page didn't match an excerpt in the catalogue. Search below, or carry on without one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(model.candidates) { excerpt in
                    ScanExcerptChoiceRow(excerpt: excerpt) {
                        model.confirmExcerpt(excerpt)
                    }
                }
            }
        } header: {
            Text("Best matches")
        }
    }

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.inkFaint)
                TextField("Composer, work or excerpt", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
            if !trimmedQuery.isEmpty {
                searchResultRows
            }
        } header: {
            Text("Search the catalogue")
        }
    }

    @ViewBuilder
    private var searchResultRows: some View {
        if searchResults.isEmpty {
            Text("No excerpts match.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
        } else {
            ForEach(searchResults) { excerpt in
                ScanExcerptChoiceRow(excerpt: excerpt) {
                    model.confirmExcerpt(excerpt)
                }
            }
        }
    }

    private var otherwiseSection: some View {
        Section {
            Button {
                model.confirmExcerpt(nil)
            } label: {
                Label("It's not in the list", systemImage: "arrow.right.circle")
            }
            Button {
                model.cropAgain()
            } label: {
                Label("Mark the excerpt again", systemImage: "crop")
            }
        } footer: {
            Text("Without an excerpt you still get reference audio; the excerpt page (tempo, techniques, recordings) needs a catalogue match.")
        }
    }
}

/// One selectable catalogue entry.
struct ScanExcerptChoiceRow: View {
    let excerpt: Excerpt
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(excerpt.workHeading)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text(excerpt.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer(minLength: 0)
                if excerpt.listingStatus != .published {
                    TagPill(text: String(localized: "Draft"), color: Theme.brass)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Consent

/// Shown once, right before the first upload. Keep the wording accurate (App Store guideline 5.1.1 / 5.1.2).
struct ScanConsentView: View {
    let onAgree: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.teal)
                    .frame(maxWidth: .infinity)
                Text("To read the notes, the app sends the part of the page you marked to the Auditioner server.")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 12) {
                    ScanConsentLine(symbol: "music.note", text: String(localized: "It's used only to read the notes on it."))
                    ScanConsentLine(symbol: "trash", text: String(localized: "It's deleted right after that — within 24 hours at the latest."))
                    ScanConsentLine(symbol: "nosign", text: String(localized: "It's never sent to any AI service."))
                    ScanConsentLine(symbol: "person.crop.circle.badge.xmark", text: String(localized: "No account needed. The app only sends a random number for this install, so the server can limit scans per device; it doesn't identify you."))
                }
                Text("The rest of the app — the catalogue, excerpt pages, recordings and your parts — works without sending anything.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                VStack(spacing: 10) {
                    Button(action: onAgree) {
                        Text("Agree and continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(action: onNotNow) {
                        Text("Not now")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }
}

private struct ScanConsentLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(Theme.teal)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Server not set up

struct ScanNeedsServerView: View {
    let hasExcerpt: Bool
    let onOpenExcerpt: () -> Void
    let onTryDemo: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkSoft)
            Text("Reading notes needs the Auditioner server, which isn't set up yet.")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Once it is, add its address under Settings → Server. Your page stays on this device until then.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                if hasExcerpt {
                    Button(action: onOpenExcerpt) {
                        Text("Open the excerpt page")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if ScoreDocument.demoScale() != nil {
                    if hasExcerpt {
                        Button(action: onTryDemo) {
                            Text("Try the demo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button(action: onTryDemo) {
                            Text("Try the demo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                Button(action: onClose) {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(24)
    }
}

// MARK: - Waiting for the server

struct ScanRecognizingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Reading the notes… this can take up to a minute.")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("The first scan after a quiet spell is the slowest, while the server wakes up.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Failure

struct ScanFailedView: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.garnet)
            Text(message)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                if canRetry {
                    Button(action: onRetry) {
                        Text("Retry")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button(action: onClose) {
                    Text("Close")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(24)
    }
}
