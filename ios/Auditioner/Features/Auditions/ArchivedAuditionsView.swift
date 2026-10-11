import SwiftUI
import SwiftData

/// The archived auditions (PLAN F5): each can be put back into "My auditions" or deleted for good.
/// Archiving is the undo-able "delete"; only this screen deletes anything.
struct ArchivedAuditionsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Audition.createdAt, order: .reverse) private var auditions: [Audition]
    @Query private var allItems: [AuditionItem]

    /// The audition whose "Delete for good" is being confirmed.
    @State private var deleting: Audition? = nil

    private var archived: [Audition] {
        AuditionArchive.archivedFirst(auditions.filter { $0.isArchived })
    }

    private func ratings(for audition: Audition) -> [Int?] {
        allItems.filter { $0.auditionId == audition.id }.map { $0.readiness }
    }

    var body: some View {
        List {
            Section {
                if archived.isEmpty {
                    AuditionsNoteRow(symbol: "archivebox",
                                     title: String(localized: "Nothing archived"),
                                     detail: String(localized: "Archive audition on an audition's page moves it here. You can restore it any time."))
                }
                ForEach(archived) { audition in
                    ArchivedAuditionRow(audition: audition,
                                        ratings: ratings(for: audition),
                                        onRestore: { restore(audition) },
                                        onDelete: { deleting = audition })
                }
            } footer: {
                if !archived.isEmpty {
                    Text("Restore puts an audition back into My auditions with its list and readiness; reminders that were on are set again. Delete for good removes it from this device.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Archived auditions")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(Text("Delete this audition for good?"), isPresented: deleteBinding, titleVisibility: .visible, presenting: deleting) { audition in
            Button("Delete for good", role: .destructive) { deleteForGood(audition) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deletes this audition and its list for good. This can't be undone.")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { newValue in if !newValue { deleting = nil } }
        )
    }

    // MARK: Actions

    private func restore(_ audition: Audition) {
        do {
            try AuditionsStore.restore(audition, context: modelContext)
        } catch {
            NSLog("Auditioner: restoring the audition failed: %@", error.localizedDescription)
            return
        }
        if audition.remindersEnabled {
            Task {
                await AuditionReminderCenter.shared.reschedule(for: audition)
            }
        }
    }

    private func deleteForGood(_ audition: Audition) {
        AuditionReminderCenter.shared.cancel(auditionId: audition.id)
        AuditionsStore.delete(audition, context: modelContext)
    }
}

/// One archived audition: the usual summary plus Restore and Delete for good.
struct ArchivedAuditionRow: View {
    let audition: Audition
    let ratings: [Int?]
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuditionSummaryRow(audition: audition, ratings: ratings)
            HStack(spacing: 16) {
                Button {
                    onRestore()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete for good", systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(.leading, 58)
        }
        .padding(.vertical, 2)
    }
}
