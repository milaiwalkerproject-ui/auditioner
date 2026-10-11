import SwiftUI
import SwiftData

// Sections of "My upcoming audition". Small on purpose so the detail view stays easy for the type-checker.

// MARK: - Header

struct AuditionHeaderSection: View {
    let audition: Audition
    let ratings: [Int?]
    let remindersOn: Binding<Bool>
    let reminderNotice: String?
    let onOpenLink: (URL) -> Void
    let onEdit: () -> Void

    private var completeness: ListCompleteness {
        ListCompleteness(raw: audition.listCompleteness)
    }

    private var plannedReminders: [AuditionReminder] {
        AuditionReminderSchedule.reminders(auditionId: audition.id,
                                           orchestra: audition.orchestra,
                                           position: audition.position,
                                           deadline: audition.applicationDeadline,
                                           auditionDate: audition.auditionDate,
                                           now: Date(),
                                           calendar: Calendar.current)
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                ReadinessRing(ratings: ratings, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(audition.position.isEmpty ? audition.instrument.displayName : audition.position)
                        .font(Theme.displayFont(.title3))
                        .foregroundStyle(Theme.ink)
                    if !audition.position.isEmpty {
                        Text(audition.instrument.displayName)
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    Text(AuditionReadiness.label(ratings))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.vertical, 2)
            datesBlock
            if let note = completeness.note {
                VStack(alignment: .leading, spacing: 6) {
                    CompletenessBadge(completeness: completeness)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 2)
            }
            if let source = audition.sourceURL, let item = SafariLinkItem.make(URL(string: source)) {
                Button {
                    onOpenLink(item.url)
                } label: {
                    Label("Open official list", systemImage: "arrow.up.right.square")
                }
            }
            remindersRow
            if !audition.notes.isEmpty {
                Text(audition.notes)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }

    @ViewBuilder
    private var datesBlock: some View {
        if audition.applicationDeadline == nil && audition.auditionDate == nil {
            Button {
                onEdit()
            } label: {
                Label("Add the deadline and audition day", systemImage: "calendar.badge.plus")
            }
        } else {
            CountdownLine(label: String(localized: "Deadline"), date: audition.applicationDeadline)
            CountdownLine(label: String(localized: "Audition"), date: audition.auditionDate)
        }
    }

    @ViewBuilder
    private var remindersRow: some View {
        Toggle(isOn: remindersOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remind me")
                Text(reminderSummary)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        if let notice = reminderNotice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(Theme.garnet)
        }
    }

    private var reminderSummary: String {
        if audition.remindersEnabled {
            return AuditionReminderSchedule.summary(plannedReminders)
        }
        return String(localized: "7 days and 1 day before the deadline and the audition, at 9:00.")
    }
}

// MARK: - Practice plan

struct AuditionPracticePlanSection: View {
    let items: [AuditionItem]
    let catalog: CatalogStore
    let onOpenItem: (AuditionItem) -> Void
    let onStartMock: () -> Void

    private var practiseNext: [AuditionItem] {
        let candidates: [PracticePlanCandidate] = items.map { item in
            let excerpt: Excerpt? = item.excerptId.flatMap { catalog.excerpt(id: $0) }
            return PracticePlanCandidate(id: item.id,
                                         readiness: item.readiness,
                                         roundRank: AuditionRounds.rank(item.round),
                                         difficulty: AuditionPracticePlan.approvedDifficulty(excerpt),
                                         order: item.order,
                                         isPractisable: AuditionItemCategory(raw: item.category).isPractisable)
        }
        let top: [PracticePlanCandidate] = AuditionPracticePlan.practiseNext(candidates, limit: 3)
        return top.compactMap { candidate in items.first { $0.id == candidate.id } }
    }

    private var hasPractisableItems: Bool {
        items.contains { AuditionItemCategory(raw: $0.category).isPractisable }
    }

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(practiseNext) { item in
                    Button {
                        onOpenItem(item)
                    } label: {
                        PracticeNextRow(item: item, excerpt: item.excerptId.flatMap { catalog.excerpt(id: $0) })
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    onStartMock()
                } label: {
                    Label("Start mock audition with this list", systemImage: "music.mic")
                }
                .disabled(!hasPractisableItems)
            } header: {
                Text("Practise next")
            } footer: {
                Text("Lowest readiness first, then the earliest round, then the harder excerpt.")
            }
        }
    }
}

struct PracticeNextRow: View {
    let item: AuditionItem
    let excerpt: Excerpt?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(Theme.brass)
            VStack(alignment: .leading, spacing: 2) {
                Text(excerpt.map { AuditionBuilder.itemTitle(for: $0) } ?? item.rawText)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(AuditionReadiness.word(for: item.readiness))
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Checklist row

struct AuditionItemRow: View {
    let item: AuditionItem
    let excerpt: Excerpt?
    let onDetails: () -> Void
    let onOpenExcerpt: (Excerpt) -> Void

    @Environment(\.modelContext) private var modelContext

    private var readinessBinding: Binding<Int?> {
        Binding(
            get: { item.readiness },
            set: { newValue in
                item.readiness = AuditionReadiness.clamp(newValue)
                AuditionsStore.save(modelContext)
            }
        )
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let tempo = AuditionTempo.summary(target: item.targetBPM, achieved: item.achievedBPM) {
            parts.append(tempo)
        }
        if let practised = item.lastPractisedAt {
            parts.append(String(localized: "Practised \(AuditionDates.dayText(practised))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onDetails) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rawText)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                        if let excerpt = excerpt {
                            Text(AuditionBuilder.itemTitle(for: excerpt))
                                .font(.caption)
                                .foregroundStyle(Theme.teal)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                RatingStars(rating: readinessBinding, font: .body)
                Spacer(minLength: 8)
                if let excerpt = excerpt {
                    Button {
                        onOpenExcerpt(excerpt)
                    } label: {
                        Label("Excerpt page", systemImage: "music.note.list")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(action: onDetails) {
                        Label("Match to catalogue", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let detail = detailLine {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 2)
    }
}
