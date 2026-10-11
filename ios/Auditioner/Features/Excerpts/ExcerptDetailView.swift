import SwiftUI

/// One excerpt's page. iPhone: a single scrolling page. iPad (regular width): facts and notes
/// on the left, recordings (and the player) on the right.
struct ExcerptDetailView: View {
    let excerpt: Excerpt

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var router: AppRouter
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false

    /// Recording shown in a sheet (iPhone).
    @State private var sheetRecording: Recording? = nil
    /// Recording shown in the right column (iPad).
    @State private var columnRecording: Recording? = nil
    @State private var safariItem: SafariLinkItem? = nil
    @State private var showReferenceMissing: Bool = false
    /// "Add to my audition" (Auditions feature).
    @State private var showAddToAudition: Bool = false

    private var isWide: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if isWide {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(excerpt.workHeading)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddToAudition = true
                } label: {
                    Label("Add to my audition", systemImage: "calendar.badge.plus")
                }
            }
        }
        .sheet(item: $safariItem) { item in
            ExcerptSafariView(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $sheetRecording) { recording in
            recordingSheet(recording)
        }
        .sheet(isPresented: $showAddToAudition) {
            AddToAuditionSheet(excerpt: excerpt)
        }
        .alert("Reference not available", isPresented: $showReferenceMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The reference notation for this excerpt isn't in this version of the app yet.")
        }
    }

    // MARK: Layouts

    private var narrowLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                actions
                factsColumn
                ExcerptRecordingsSection(excerpt: excerpt, selectedRecordingId: nil) { recording in
                    sheetRecording = recording
                }
                ExcerptSourcesSection(excerpt: excerpt)
            }
            .padding(16)
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                    factsColumn
                    ExcerptSourcesSection(excerpt: excerpt)
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    columnPlayer
                    ExcerptRecordingsSection(excerpt: excerpt, selectedRecordingId: columnRecording?.id) { recording in
                        columnRecording = recording
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Pieces

    private var header: some View {
        ExcerptHeaderSection(excerpt: excerpt, reviewerMode: reviewerMode)
            .padding(.horizontal, 4)
    }

    private var actions: some View {
        ExcerptActionsSection(
            excerpt: excerpt,
            onOpenIMSLP: { url in
                safariItem = SafariLinkItem.make(url)
            },
            onReferenceMissing: {
                showReferenceMissing = true
            }
        )
    }

    @ViewBuilder
    private var factsColumn: some View {
        ExcerptFactsSection(excerpt: excerpt)
        ExcerptCopyrightSection(excerpt: excerpt)
        ExcerptFrequencySection(excerpt: excerpt)
        ExcerptNotesSection(excerpt: excerpt, reviewerMode: reviewerMode)
    }

    /// iPad: the player for the chosen recording, above the list. One player per screen.
    @ViewBuilder
    private var columnPlayer: some View {
        if let recording = columnRecording {
            ExcerptSectionBox(nil) {
                HStack {
                    Text(recording.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        columnRecording = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkFaint)
                    }
                    .accessibilityLabel(Text("Close player"))
                }
                RecordingPlayerView(recording: recording, excerpt: excerpt)
                    .id(recording.id)
            }
        }
    }

    private func recordingSheet(_ recording: Recording) -> some View {
        NavigationStack {
            ScrollView {
                RecordingPlayerView(recording: recording, excerpt: excerpt)
                    .padding(16)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle(recording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        sheetRecording = nil
                    }
                }
            }
        }
        .environmentObject(router)
    }
}
