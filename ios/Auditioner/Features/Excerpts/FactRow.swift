import SwiftUI

/// One verifiable fact on the excerpt page. Honesty contract: a value is shown only when the
/// fact is verified (with a "source" link); an unverified fact shows "Check the official list"
/// (linked to the source when there is one); `not_applicable` rows are never built.
struct FactRow: View, Identifiable {
    let label: String
    let status: FactStatus
    /// Text of the value; present only when `status == .verified`.
    let valueText: String?
    let sourceURL: URL?
    let asOf: String?
    var italic: Bool = false
    /// Caveat recorded with the fact (e.g. "As listed in BrassXcerpts; not yet re-checked against the part").
    var note: String? = nil

    var id: String { label }

    /// Builds a row from a `Verifiable`, or `nil` when the fact is missing or not applicable.
    static func make<T: Codable & Hashable>(_ label: String, _ fact: Verifiable<T>?, italic: Bool = false,
                                            text: (T) -> String) -> FactRow? {
        guard let fact = fact, !fact.isHidden else { return nil }
        let value: String? = fact.verifiedValue.map(text)
        return FactRow(label: label, status: fact.status, valueText: value,
                       sourceURL: fact.sourceURL, asOf: fact.asOf, italic: italic, note: fact.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FactLabel(text: label)
            if status == .verified, let valueText = valueText {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    valueView(valueText)
                    Spacer(minLength: 0)
                    SourceLink(url: sourceURL)
                }
                if let note = note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            } else {
                CheckOfficialListLink(url: sourceURL)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func valueView(_ text: String) -> some View {
        if italic {
            Text(text).font(.body.italic()).foregroundStyle(Theme.ink)
        } else {
            Text(text).font(.body).foregroundStyle(Theme.ink)
        }
    }
}

/// Small uppercase caption above a fact value.
struct FactLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.inkFaint)
            .textCase(.uppercase)
    }
}

/// Small "source" link next to a verified value. Draws nothing when there is no URL.
struct SourceLink: View {
    let url: URL?

    var body: some View {
        if let url = url {
            Link(destination: url) {
                Label("Source", systemImage: "link")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// What an unverified fact shows instead of a value.
struct CheckOfficialListLink: View {
    let url: URL?

    var body: some View {
        if let url = url {
            Link(destination: url) {
                Label("Check the official list", systemImage: "arrow.up.right.square")
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
        } else {
            Text("Check the official list")
                .font(.subheadline)
                .foregroundStyle(Theme.slate)
        }
    }
}

/// Rounded card used for every section of the excerpt page.
struct ExcerptSectionBox<Content: View>: View {
    let title: Text?
    let content: Content

    init(_ title: Text?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = title {
                title
                    .font(Theme.displayFont(.title3))
                    .foregroundStyle(Theme.ink)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
