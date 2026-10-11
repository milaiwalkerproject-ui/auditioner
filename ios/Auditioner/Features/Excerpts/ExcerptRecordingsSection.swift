import SwiftUI

/// Orchestra / solo recordings of the excerpt, plus the two search links the plan allows.
/// Tapping a row hands the recording to the parent (sheet on iPhone, right column on iPad).
struct ExcerptRecordingsSection: View {
    let excerpt: Excerpt
    let selectedRecordingId: String?
    let onSelect: (Recording) -> Void

    @State private var kind: RecordingKind = .orchestra
    @State private var didPickInitialKind: Bool = false

    private var recordings: [Recording] {
        excerpt.recordings ?? []
    }

    private var shown: [Recording] {
        recordings.filter { $0.kind == kind }
    }

    var body: some View {
        ExcerptSectionBox(Text("Recordings")) {
            Picker("Recording type", selection: $kind) {
                Text("Orchestra").tag(RecordingKind.orchestra)
                Text("Solo").tag(RecordingKind.solo)
            }
            .pickerStyle(.segmented)

            if shown.isEmpty {
                Text(kind == .orchestra ? String(localized: "No orchestra recordings listed yet.") : String(localized: "No solo recordings listed yet."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                ForEach(shown) { recording in
                    ExcerptRecordingRow(recording: recording, isSelected: recording.id == selectedRecordingId) {
                        onSelect(recording)
                    }
                }
            }

            Divider()
            searchLinks
        }
        .onAppear(perform: pickInitialKind)
    }

    private var searchLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = ExcerptLinks.youtubeSearchURL(for: excerpt) {
                Link(destination: url) {
                    Label("Search on YouTube", systemImage: "magnifyingglass")
                        .font(.subheadline)
                }
            }
            if let url = ExcerptLinks.appleMusicSearchURL(for: excerpt) {
                Link(destination: url) {
                    Label("Search Apple Music", systemImage: "magnifyingglass")
                        .font(.subheadline)
                }
            }
        }
    }

    /// Start on "Solo" when the excerpt only has solo recordings.
    private func pickInitialKind() {
        guard !didPickInitialKind else { return }
        didPickInitialKind = true
        let hasOrchestra = recordings.contains { $0.kind == .orchestra }
        let hasSolo = recordings.contains { $0.kind == .solo }
        if !hasOrchestra && hasSolo {
            kind = .solo
        }
    }
}

struct ExcerptRecordingRow: View {
    let recording: Recording
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: providerSymbol)
                    .font(.title3)
                    .foregroundStyle(Theme.garnet)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    if let performer = recording.performer, !performer.isEmpty {
                        Text(performer)
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                            .multilineTextAlignment(.leading)
                    }
                    Text(providerName)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.inkFaint)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var providerSymbol: String {
        switch recording.provider {
        case .youtube: return "play.rectangle"
        case .appleMusic: return "music.note"
        case .hosted: return "waveform"
        case .link: return "link"
        }
    }

    private var providerName: String {
        switch recording.provider {
        case .youtube: return "YouTube"
        case .appleMusic: return "Apple Music"
        case .hosted: return String(localized: "Free-licence recording")
        case .link: return String(localized: "External link")
        }
    }
}
