import Foundation
import UserNotifications

/// One local notification the app plans for an audition.
struct AuditionReminder: Equatable, Identifiable {
    let identifier: String
    let fireDate: Date
    let title: String
    let body: String

    var id: String { identifier }
}

/// Pure planning of the reminders (unit-tested with a fixed calendar): 7 days and 1 day before the
/// application deadline and before the audition day, at 9:00 in the calendar's time zone.
/// Reminders whose time has already passed are not planned.
enum AuditionReminderSchedule {
    static let hour: Int = 9
    static let minute: Int = 0
    static let dayOffsets: [Int] = [7, 1]

    enum Kind: String, CaseIterable {
        case deadline
        case audition
    }

    /// "audition-<uuid>-deadline-7": stable, so the same audition can be rescheduled or cancelled later.
    static func identifier(auditionId: UUID, kind: Kind, daysBefore: Int) -> String {
        "audition-\(auditionId.uuidString.lowercased())-\(kind.rawValue)-\(daysBefore)"
    }

    /// Every identifier an audition can own (for cancelling).
    static func identifiers(auditionId: UUID) -> [String] {
        var result: [String] = []
        for kind in Kind.allCases {
            for days in dayOffsets {
                result.append(identifier(auditionId: auditionId, kind: kind, daysBefore: days))
            }
        }
        return result
    }

    /// 9:00 on the day `daysBefore` days before `day`, in the calendar's time zone.
    static func fireDate(before day: Date, daysBefore: Int, calendar: Calendar) -> Date? {
        let start: Date = calendar.startOfDay(for: day)
        guard let shifted = calendar.date(byAdding: .day, value: -daysBefore, to: start) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted)
    }

    static func reminders(auditionId: UUID,
                          orchestra: String,
                          position: String,
                          deadline: Date?,
                          auditionDate: Date?,
                          now: Date,
                          calendar: Calendar) -> [AuditionReminder] {
        var result: [AuditionReminder] = []
        let who: String = position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? orchestra
            : "\(orchestra) (\(position))"
        if let deadline = deadline {
            for days in dayOffsets {
                guard let fire = fireDate(before: deadline, daysBefore: days, calendar: calendar), fire > now else { continue }
                let when: String = AuditionCountdown.phrase(days: days)
                result.append(AuditionReminder(identifier: identifier(auditionId: auditionId, kind: .deadline, daysBefore: days),
                                               fireDate: fire,
                                               title: String(localized: "Application deadline \(when)"),
                                               body: String(localized: "\(who): applications close \(AuditionDates.dayText(deadline, calendar: calendar))."))
                )
            }
        }
        if let auditionDate = auditionDate {
            for days in dayOffsets {
                guard let fire = fireDate(before: auditionDate, daysBefore: days, calendar: calendar), fire > now else { continue }
                let when: String = AuditionCountdown.phrase(days: days)
                result.append(AuditionReminder(identifier: identifier(auditionId: auditionId, kind: .audition, daysBefore: days),
                                               fireDate: fire,
                                               title: String(localized: "Audition \(when)"),
                                               body: String(localized: "\(who): audition on \(AuditionDates.dayText(auditionDate, calendar: calendar))."))
                )
            }
        }
        return result.sorted { $0.fireDate < $1.fireDate }
    }

    /// Plain-words line under the toggle: what will be sent.
    static func summary(_ reminders: [AuditionReminder], calendar: Calendar = .current) -> String {
        if reminders.isEmpty {
            return String(localized: "Both dates have passed or aren't set — nothing to remind you of yet.")
        }
        let days: [String] = reminders.map { AuditionDates.dayText($0.fireDate, calendar: calendar) }
        return String(localized: "Reminders at 9:00 on \(days.joined(separator: ", ")).")
    }
}

/// Talks to the system notification centre. Main actor only.
@MainActor
final class AuditionReminderCenter {
    static let shared = AuditionReminderCenter()

    private let center: UNUserNotificationCenter = UNUserNotificationCenter.current()

    /// Asks the first time; afterwards just reports whether reminders may be shown.
    func ensureAuthorized() async -> Bool {
        let settings: UNNotificationSettings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Replaces the audition's reminders with the current plan (none when reminders are off).
    func reschedule(for audition: Audition, now: Date = Date(), calendar: Calendar = .current) async {
        let auditionId: UUID = audition.id
        center.removePendingNotificationRequests(withIdentifiers: AuditionReminderSchedule.identifiers(auditionId: auditionId))
        guard audition.remindersEnabled else { return }
        let planned: [AuditionReminder] = AuditionReminderSchedule.reminders(auditionId: auditionId,
                                                                             orchestra: audition.orchestra,
                                                                             position: audition.position,
                                                                             deadline: audition.applicationDeadline,
                                                                             auditionDate: audition.auditionDate,
                                                                             now: now,
                                                                             calendar: calendar)
        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = UNNotificationSound.default
            let components: DateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                NSLog("Auditioner: couldn't schedule a reminder: %@", error.localizedDescription)
            }
        }
    }

    func cancel(auditionId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: AuditionReminderSchedule.identifiers(auditionId: auditionId))
    }
}
