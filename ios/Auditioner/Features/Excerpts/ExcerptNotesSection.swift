import SwiftUI

/// One prose block ready for display.
struct ExcerptProseItem: Identifiable {
    /// "history", "technique", "pitfalls" or "practiceTips" (also the feedback key).
    let id: String
    let title: String
    let block: ProseBlock
    /// Machine translation of `block.text` in the app's language, when one may be shown
    /// (PLAN A7b: only from 12 Nov 2026, only for approved notes). nil → the English is shown.
    var translation: String? = nil
}

/// What the notes section lists for one excerpt.
struct ExcerptNotesListing {
    var items: [ExcerptProseItem]
    /// Notes dropped because AI notes are hidden in this region (PLAN A6). When > 0 the section says
    /// once "Some notes aren't available in your region."
    var hiddenByRegion: Int
}

/// History / technique / pitfalls / practice tips. Honesty contract: a block is shown only when
/// approved, or in reviewer mode (then with a "Draft — not reviewed" banner). AI text always
/// carries the AI label with thumbs up/down and "Report an error" — also a machine translation,
/// whichever origin the English has. Below the notes (or on its own when there are none) sits a
/// quiet page-level "Report an error" link for the facts.
/// In another app language an approved note may show its machine translation instead of the
/// English (`NoteTranslations`), with a "Machine-translated" pill and a "Show original" toggle.
/// In Hong Kong and Macau (PLAN A6, `AINotesAvailability`) AI notes and translations are left out.
struct ExcerptNotesSection: View {
    let excerpt: Excerpt
    let reviewerMode: Bool

    @ObservedObject private var translations: NoteTranslations = NoteTranslations.shared
    @ObservedObject private var aiNotes: AINotesAvailability = AINotesAvailability.shared

    private var listing: ExcerptNotesListing {
        ExcerptNotesLogic.listing(for: excerpt,
                                  reviewerMode: reviewerMode,
                                  translations: translations,
                                  hidesAINotes: aiNotes.hidesAINotes)
    }

    var body: some View {
        let listing: ExcerptNotesListing = self.listing
        return VStack(alignment: .leading, spacing: 14) {
            if !listing.items.isEmpty || listing.hiddenByRegion > 0 {
                ExcerptSectionBox(Text("Notes")) {
                    ForEach(listing.items) { item in
                        ExcerptProseBlockView(excerptId: excerpt.id, item: item, reviewerMode: reviewerMode)
                    }
                    if listing.hiddenByRegion > 0 {
                        Label("Some notes aren't available in your region.", systemImage: "globe")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.top, 2)
                    }
                }
            }
            ExcerptReportErrorLink(excerptId: excerpt.id)
        }
    }
}

/// The pure part of the notes section, kept off the `View` type so the tests can call it from any
/// context (`View` is main-actor-isolated in the iOS 18+ SDK; a static on the view would inherit that).
enum ExcerptNotesLogic {
    /// The notes to show, in page order, and how many the region rule dropped. The approved-only
    /// rule comes first: a block is listed only when approved (or in reviewer mode), and a translation
    /// is attached only to an approved block — a draft is never shown translated, whatever the mode.
    /// With `hidesAINotes` (PLAN A6) every AI block is left out, in any mode, and no translation is
    /// attached to the curated ones (a translation is AI prose). Pure, so it can be unit-tested.
    static func listing(for excerpt: Excerpt,
                        reviewerMode: Bool,
                        translations: NoteTranslations,
                        hidesAINotes: Bool) -> ExcerptNotesListing {
        guard let prose: ExcerptProse = excerpt.prose else {
            return ExcerptNotesListing(items: [], hiddenByRegion: 0)
        }
        let fields: [(id: String, title: String, block: ProseBlock?)] = [
            (id: "history", title: String(localized: "History"), block: prose.history),
            (id: "technique", title: String(localized: "Technique"), block: prose.technique),
            (id: "pitfalls", title: String(localized: "Common pitfalls"), block: prose.pitfalls),
            (id: "practiceTips", title: String(localized: "Practice tips"), block: prose.practiceTips),
        ]
        var items: [ExcerptProseItem] = []
        var hidden: Int = 0
        for field in fields {
            guard let block: ProseBlock = field.block else { continue }
            guard block.isApproved || reviewerMode else { continue }
            if hidesAINotes && block.origin == .ai {
                hidden += 1
                continue
            }
            let translation: String? = (block.isApproved && !hidesAINotes)
                ? translations.translation(excerptId: excerpt.id, field: field.id)
                : nil
            items.append(ExcerptProseItem(id: field.id, title: field.title, block: block, translation: translation))
        }
        return ExcerptNotesListing(items: items, hiddenByRegion: hidden)
    }

    /// The notes to show, in page order (see `listing`).
    static func proseItems(for excerpt: Excerpt,
                           reviewerMode: Bool,
                           translations: NoteTranslations,
                           hidesAINotes: Bool = false) -> [ExcerptProseItem] {
        listing(for: excerpt, reviewerMode: reviewerMode, translations: translations, hidesAINotes: hidesAINotes).items
    }
}

struct ExcerptProseBlockView: View {
    let excerptId: String
    let item: ExcerptProseItem
    let reviewerMode: Bool

    /// "" (no vote), "up" or "down". Stored only on this device.
    @AppStorage private var vote: String
    @State private var isReporting: Bool = false
    /// "Show original" tapped: the English instead of the translation. Per note, translation first.
    @State private var showsOriginal: Bool = false

    init(excerptId: String, item: ExcerptProseItem, reviewerMode: Bool) {
        self.excerptId = excerptId
        self.item = item
        self.reviewerMode = reviewerMode
        _vote = AppStorage(wrappedValue: "", "feedback.\(excerptId).\(item.id)")
    }

    private var block: ProseBlock { item.block }

    private var displayedText: String {
        NoteTranslationDisplay.text(original: block.text, translation: item.translation, showsOriginal: showsOriginal)
    }

    private var showsMachineTranslatedTag: Bool {
        NoteTranslationDisplay.showsMachineTranslatedTag(translation: item.translation, showsOriginal: showsOriginal)
    }

    /// The AI label belongs under AI notes and under any note while its translation is on screen.
    private var showsAIFooter: Bool {
        NoteTranslationDisplay.showsAIFooter(origin: block.origin, translation: item.translation, showsOriginal: showsOriginal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                if block.origin == .curated && block.isApproved {
                    TagPill(text: String(localized: "Curated"), color: Theme.teal)
                }
                if showsMachineTranslatedTag {
                    TagPill(text: String(localized: "Machine-translated"), color: Theme.brass)
                }
            }
            if !block.isApproved {
                draftBanner
            }
            Text(displayedText)
                .font(.body)
                .foregroundStyle(Theme.ink)
            if item.translation != nil {
                translationToggle
            }
            if showsAIFooter {
                aiFooter
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $isReporting) {
            ReportProblemSheet(context: "excerpt-note:\(item.id)", excerptId: excerptId)
        }
    }

    /// Swaps the translation and the English for this note only.
    private var translationToggle: some View {
        let title: String = showsOriginal
            ? String(localized: "Show translation")
            : String(localized: "Show original")
        return Button(title) {
            showsOriginal.toggle()
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.slate)
    }

    private var draftBannerText: String {
        if block.reviewStatus == .rejected {
            return String(localized: "Rejected — not shown to users")
        }
        return String(localized: "Draft — not reviewed")
    }

    private var draftBanner: some View {
        Label(draftBannerText, systemImage: "eye.slash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var aiFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI-generated — may contain errors, check against your part", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(Theme.garnet)
            HStack(spacing: 14) {
                Button {
                    vote = (vote == "up") ? "" : "up"
                } label: {
                    Image(systemName: vote == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .accessibilityLabel(Text("Helpful"))
                Button {
                    vote = (vote == "down") ? "" : "down"
                } label: {
                    Image(systemName: vote == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .accessibilityLabel(Text("Not helpful"))
                Button("Report an error") {
                    isReporting = true
                }
                .font(.caption)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.slate)
        }
    }
}
