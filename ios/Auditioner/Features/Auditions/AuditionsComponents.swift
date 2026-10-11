import SwiftUI

// Small views shared by the Auditions screens. Each takes plain values so the bigger
// views stay quick for the type-checker.

// MARK: - Readiness ring

/// Share of items rated 4–5, as a ring with the count inside.
struct ReadinessRing: View {
    let ratings: [Int?]
    var size: CGFloat = 44

    private var share: Double {
        AuditionReadiness.share(ratings)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.inkFaint.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(share))
                .stroke(share >= 0.999 ? Theme.teal : Theme.brass, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(centreText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Readiness"))
        .accessibilityValue(Text(AuditionReadiness.label(ratings)))
    }

    private var centreText: String {
        if ratings.isEmpty { return "–" }
        return "\(AuditionReadiness.readyCount(ratings))/\(ratings.count)"
    }
}

// MARK: - Completeness pill

struct CompletenessBadge: View {
    let completeness: ListCompleteness

    var body: some View {
        if let text = completeness.badgeText {
            TagPill(text: text, color: completeness == .full ? Theme.teal : Theme.slate)
        }
    }
}

// MARK: - Countdown line

/// "Deadline 3 Nov 2026 · in 23 days", in garnet once it has passed.
struct CountdownLine: View {
    let label: String
    let date: Date?
    var now: Date = Date()

    var body: some View {
        if let date = date {
            let days: Int = AuditionCountdown.days(from: now, to: date, calendar: Calendar.current)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                Text(AuditionDates.dayText(date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("· \(AuditionCountdown.phrase(days: days))")
                    .font(.subheadline)
                    .foregroundStyle(AuditionCountdown.isPast(days: days) ? Theme.garnet : Theme.inkSoft)
            }
        }
    }
}

// MARK: - Source line

/// "From <orchestra>'s website, checked <date>" with the "Open official list" link next to it.
struct FeedSourceLine: View {
    let orchestra: String
    let lastCheckedAt: String?
    let sourceURL: String
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OpenAuditionsLogic.sourceLine(orchestra: orchestra, lastCheckedAt: lastCheckedAt))
                .font(.caption)
                .foregroundStyle(Theme.inkFaint)
            if let item = SafariLinkItem.make(URL(string: sourceURL)) {
                Button {
                    onOpen(item.url)
                } label: {
                    Label("Open official list", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Plain explanation rows

/// A quiet explanation used for empty states inside a list section.
struct AuditionsNoteRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rows

/// One of the player's auditions in the list.
struct AuditionSummaryRow: View {
    let audition: Audition
    let ratings: [Int?]
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 14) {
            ReadinessRing(ratings: ratings)
            VStack(alignment: .leading, spacing: 3) {
                Text(audition.orchestra.isEmpty ? String(localized: "Untitled audition") : audition.orchestra)
                    .font(Theme.displayFont(.headline))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if !audition.position.isEmpty {
                    Text(audition.position)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                }
                Text(dateLine)
                    .font(.caption)
                    .foregroundStyle(dateIsPast ? Theme.garnet : Theme.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }

    private var countdownTarget: (label: String, date: Date)? {
        if let auditionDate = audition.auditionDate { return (String(localized: "Audition"), auditionDate) }
        if let deadline = audition.applicationDeadline { return (String(localized: "Deadline"), deadline) }
        return nil
    }

    private var dateLine: String {
        guard let target = countdownTarget else { return String(localized: "No date yet") }
        let phrase: String = AuditionCountdown.phrase(to: target.date, now: now, calendar: Calendar.current)
        return String(localized: "\(target.label) \(phrase) · \(AuditionDates.dayText(target.date))")
    }

    private var dateIsPast: Bool {
        guard let target = countdownTarget else { return false }
        return AuditionCountdown.isPast(days: AuditionCountdown.days(from: now, to: target.date, calendar: Calendar.current))
    }
}

/// One open audition from the feed.
struct FeedVacancyRow: View {
    let vacancy: FeedVacancy
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vacancy.orchestra)
                .font(Theme.displayFont(.headline))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text(vacancy.position)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(2)
            Text(deadlineLine)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            CompletenessBadge(completeness: ListCompleteness(raw: vacancy.listCompleteness))
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private var deadlineLine: String {
        if let deadline = AuditionDates.parseDay(vacancy.applicationDeadline, calendar: Calendar.current) {
            let phrase: String = AuditionCountdown.phrase(to: deadline, now: now, calendar: Calendar.current)
            return String(localized: "Deadline \(AuditionDates.dayText(deadline)) · \(phrase)")
        }
        return String(localized: "Deadline: check the official list")
    }
}
