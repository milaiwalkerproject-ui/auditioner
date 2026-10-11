import SwiftUI

/// Search the catalogue for the player's instrument and confirm the excerpt a list line stands for.
/// Nothing is linked until the player confirms the alert.
struct AuditionMatchPickerView: View {
    let instrument: Instrument
    let initialQuery: String
    let onChoose: (Excerpt) -> Void

    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage(SettingsKey.reviewerMode) private var reviewerMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var pending: Excerpt? = nil

    init(instrument: Instrument, initialQuery: String, onChoose: @escaping (Excerpt) -> Void) {
        self.instrument = instrument
        self.initialQuery = initialQuery
        self.onChoose = onChoose
        _query = State(initialValue: initialQuery)
    }

    private var results: [Excerpt] {
        catalog.search(query, instrument: instrument, includeDrafts: reviewerMode)
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { newValue in if !newValue { pending = nil } }
        )
    }

    var body: some View {
        List {
            if results.isEmpty {
                Text("Nothing in the \(instrument.displayName.lowercased()) catalogue matches. Try just the composer's surname, or leave the line unlinked.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
            }
            ForEach(results) { excerpt in
                Button {
                    pending = excerpt
                } label: {
                    ExcerptRow(excerpt: excerpt, reviewerMode: reviewerMode)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .searchable(text: $query, prompt: Text("Composer, work or excerpt"))
        .navigationTitle("Match to catalogue")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Link this line?", isPresented: pendingBinding, presenting: pending) { excerpt in
            Button("Link") {
                onChoose(excerpt)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { excerpt in
            Text(AuditionBuilder.itemTitle(for: excerpt))
        }
    }
}
