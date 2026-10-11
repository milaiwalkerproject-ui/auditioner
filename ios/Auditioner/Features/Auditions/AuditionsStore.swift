import Foundation
import SwiftData

/// SwiftData helpers for "My upcoming audition". Everything private to the device (PLAN F4).
enum AuditionsStore {

    // MARK: Fetching

    static func audition(id: UUID, context: ModelContext) -> Audition? {
        let descriptor = FetchDescriptor<Audition>(predicate: #Predicate<Audition> { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    /// The audition already made from this feed vacancy, if any (so "Prepare" never duplicates).
    static func audition(vacancyId: String, context: ModelContext) -> Audition? {
        // Few auditions per player: filtering in memory avoids optional-field predicates.
        let all: [Audition] = (try? context.fetch(FetchDescriptor<Audition>())) ?? []
        return all.first { $0.vacancyId == vacancyId }
    }

    /// Items of one audition in list order.
    static func items(for auditionId: UUID, context: ModelContext) -> [AuditionItem] {
        var descriptor = FetchDescriptor<AuditionItem>(predicate: #Predicate<AuditionItem> { $0.auditionId == auditionId })
        descriptor.sortBy = [SortDescriptor(\AuditionItem.order)]
        return (try? context.fetch(descriptor)) ?? []
    }

    static func nextOrder(for auditionId: UUID, context: ModelContext) -> Int {
        AuditionBuilder.nextOrder(existingOrders: items(for: auditionId, context: context).map { $0.order })
    }

    // MARK: Creating

    /// Creates the audition and its checklist from a feed vacancy, or returns the one made earlier.
    @discardableResult
    static func prepare(from vacancy: FeedVacancy, fallbackInstrument: Instrument, context: ModelContext,
                        calendar: Calendar = .current) throws -> Audition {
        if let existing = audition(vacancyId: vacancy.id, context: context) {
            return existing
        }
        let audition: Audition = AuditionBuilder.audition(from: vacancy, fallbackInstrument: fallbackInstrument, calendar: calendar)
        context.insert(audition)
        for item in AuditionBuilder.items(from: vacancy, auditionId: audition.id) {
            context.insert(item)
        }
        try context.save()
        return audition
    }

    /// Appends items after the existing ones, renumbering them in the given sequence.
    static func append(_ items: [AuditionItem], to audition: Audition, context: ModelContext) throws {
        var order: Int = nextOrder(for: audition.id, context: context)
        for item in items {
            item.auditionId = audition.id
            item.order = order
            order += 1
            context.insert(item)
        }
        try context.save()
    }

    /// Adds one catalogue excerpt as a line. Returns `false` when it is already on the list.
    @discardableResult
    static func add(excerpt: Excerpt, to audition: Audition, round: String = "", context: ModelContext) throws -> Bool {
        let existing: [AuditionItem] = items(for: audition.id, context: context)
        if existing.contains(where: { $0.excerptId == excerpt.id }) {
            return false
        }
        let item: AuditionItem = AuditionBuilder.item(for: excerpt, auditionId: audition.id,
                                                      order: AuditionBuilder.nextOrder(existingOrders: existing.map { $0.order }),
                                                      round: round)
        context.insert(item)
        try context.save()
        return true
    }

    /// Adds one typed line.
    static func add(text: String, round: String, category: AuditionItemCategory, excerptId: String?,
                    to audition: Audition, context: ModelContext) throws {
        let cleaned: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let item = AuditionItem(auditionId: audition.id, order: nextOrder(for: audition.id, context: context), rawText: cleaned)
        item.round = AuditionRounds.canonical(round)
        item.category = category.rawValue
        item.excerptId = AuditionBuilder.cleanExcerptId(excerptId)
        context.insert(item)
        try context.save()
    }

    // MARK: Changing

    /// Moves rows inside one section; the section keeps its place among the others.
    static func move(_ sectionItems: [AuditionItem], from source: IndexSet, to destination: Int, context: ModelContext) {
        let newOrders: [Int] = AuditionBuilder.reorderedOrders(sectionItems.map { $0.order }, from: source, to: destination)
        guard newOrders.count == sectionItems.count else { return }
        for (index, item) in sectionItems.enumerated() {
            item.order = newOrders[index]
        }
        try? context.save()
    }

    static func delete(_ item: AuditionItem, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    /// Deletes the audition and its items; the caller cancels the reminders.
    static func delete(_ audition: Audition, context: ModelContext) {
        for item in items(for: audition.id, context: context) {
            context.delete(item)
        }
        context.delete(audition)
        try? context.save()
    }

    static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            NSLog("Auditioner: saving the audition failed: %@", error.localizedDescription)
        }
    }
}
