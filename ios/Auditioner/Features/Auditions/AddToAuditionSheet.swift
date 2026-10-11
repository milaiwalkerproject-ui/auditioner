import SwiftUI
import SwiftData

/// From an excerpt page: put this excerpt on one of my audition lists.
struct AddToAuditionSheet: View {
    let excerpt: Excerpt

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audition.createdAt, order: .reverse) private var auditions: [Audition]

    @State private var isCreating: Bool = false
    @State private var message: String? = nil

    /// Archived auditions are left out: restore one from the Auditions tab first.
    private var sorted: [Audition] {
        auditions.filter { !$0.isArchived }.sorted { a, b in
            let da: Date = AuditionOrdering.sortDate(auditionDate: a.auditionDate, deadline: a.applicationDeadline)
            let db: Date = AuditionOrdering.sortDate(auditionDate: b.auditionDate, deadline: b.applicationDeadline)
            if da != db { return da < db }
            return a.createdAt > b.createdAt
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { message != nil },
            set: { newValue in if !newValue { message = nil } }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(AuditionBuilder.itemTitle(for: excerpt))
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                }
                Section {
                    if sorted.isEmpty {
                        Text("You haven't added an audition yet.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    ForEach(sorted) { audition in
                        Button {
                            add(to: audition)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(audition.orchestra.isEmpty ? String(localized: "Untitled audition") : audition.orchestra)
                                    .font(.body)
                                    .foregroundStyle(Theme.ink)
                                if !audition.position.isEmpty {
                                    Text(audition.position)
                                        .font(.caption)
                                        .foregroundStyle(Theme.inkSoft)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        isCreating = true
                    } label: {
                        Label("New audition", systemImage: "plus")
                    }
                } header: {
                    Text("My auditions")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Add to my audition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                AuditionFormView(mode: .create) { created in
                    add(to: created)
                }
            }
        }
        .alert("Not added", isPresented: messageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func add(to audition: Audition) {
        do {
            let added: Bool = try AuditionsStore.add(excerpt: excerpt, to: audition, context: modelContext)
            if added {
                dismiss()
            } else {
                message = String(localized: "This excerpt is already on that list.")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
