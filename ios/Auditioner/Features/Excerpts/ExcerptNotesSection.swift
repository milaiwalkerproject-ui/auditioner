import SwiftUI

/// One prose block ready for display.
struct ExcerptProseItem: Identifiable {
    /// "history", "technique", "pitfalls" or "practiceTips" (also the feedback key).
    let id: String
    let title: String
    let block: ProseBlock
}

/// History / technique / pitfalls / practice tips. Honesty contract: a block is shown only when
/// approved, or in reviewer mode (then with a "Draft — not reviewed" banner). AI text always
/// carries the AI label with thumbs up/down and "Report an error".
struct ExcerptNotesSection: View {
    let excerpt: Excerpt
    let reviewerMode: Bool

    private var items: [ExcerptProseItem] {
        guard let prose = excerpt.prose else { return [] }
        var result: [ExcerptProseItem] = []
        if let block = prose.history {
            result.append(ExcerptProseItem(id: "history", title: String(localized: "History"), block: block))
        }
        if let block = prose.technique {
            result.append(ExcerptProseItem(id: "technique", title: String(localized: "Technique"), block: block))
        }
        if let block = prose.pitfalls {
            result.append(ExcerptProseItem(id: "pitfalls", title: String(localized: "Common pitfalls"), block: block))
        }
        if let block = prose.practiceTips {
            result.append(ExcerptProseItem(id: "practiceTips", title: String(localized: "Practice tips"), block: block))
        }
        return result.filter { $0.block.isApproved || reviewerMode }
    }

    var body: some View {
        if !items.isEmpty {
            ExcerptSectionBox(Text("Notes")) {
                ForEach(items) { item in
                    ExcerptProseBlockView(excerptId: excerpt.id, item: item, reviewerMode: reviewerMode)
                }
            }
        }
    }
}

struct ExcerptProseBlockView: View {
    let excerptId: String
    let item: ExcerptProseItem
    let reviewerMode: Bool

    /// "" (no vote), "up" or "down". Stored only on this device.
    @AppStorage private var vote: String
    @Environment(\.openURL) private var openURL

    init(excerptId: String, item: ExcerptProseItem, reviewerMode: Bool) {
        self.excerptId = excerptId
        self.item = item
        self.reviewerMode = reviewerMode
        _vote = AppStorage(wrappedValue: "", "feedback.\(excerptId).\(item.id)")
    }

    private var block: ProseBlock { item.block }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                if block.origin == .curated && block.isApproved {
                    TagPill(text: String(localized: "Curated"), color: Theme.teal)
                }
            }
            if !block.isApproved {
                draftBanner
            }
            Text(block.text)
                .font(.body)
                .foregroundStyle(Theme.ink)
            if block.origin == .ai {
                aiFooter
            }
        }
        .padding(.vertical, 4)
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
                if let reportURL = FeedbackConfig.reportURL(excerptId: excerptId, section: item.id, origin: block.origin) {
                    Button("Report an error") {
                        openURL(reportURL)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.slate)
        }
    }
}
