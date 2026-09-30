import AppKit
import EventKit
import Foundation

/// A Reminders list the new reminder can go to.
struct ReminderList: Identifiable, Equatable {
    var id: String
    var title: String
    var color: NSColor?
}

/// An open reminder already due the same day (the card shows a few for context).
struct DueReminder: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var due: Date?
}

/// What the card adds.
struct ReminderDraft: Sendable {
    var title: String
    var due: Date?
    var repeatRule: ReminderRequest.Repeat
    var highPriority: Bool
    var listID: String?
}

/// Reads lists and due reminders and adds new ones, through EventKit.
final class ReminderStore: @unchecked Sendable {
    static let shared = ReminderStore()

    private let store = EKEventStore()
    private let lock = NSLock()

    var status: Permissions.State {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted {
            lock.lock()
            store.reset()   // lists load only after access is granted
            lock.unlock()
        }
        return granted
    }

    /// Writable lists, the default one first.
    func lists() -> (all: [ReminderList], defaultID: String?) {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted else { return ([], nil) }
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let all = store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, color: NSColor(cgColor: $0.cgColor)) }
            .sorted { ($0.id == defaultID ? 0 : 1, $0.title) < ($1.id == defaultID ? 0 : 1, $1.title) }
        return (all, defaultID)
    }

    /// Open reminders due on `day` (start of day), soonest first.
    func due(on day: Date, calendar cal: Calendar) async -> [DueReminder] {
        guard status == .granted, let end = cal.date(byAdding: .day, value: 1, to: day) else { return [] }
        let store = self.store
        let predicate: NSPredicate = {
            lock.lock(); defer { lock.unlock() }
            return store.predicateForIncompleteReminders(withDueDateStarting: day, ending: end, calendars: nil)
        }()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[DueReminder], Never>) in
            _ = store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { r in
                    DueReminder(id: r.calendarItemIdentifier, title: r.title ?? "",
                                due: r.dueDateComponents.flatMap { cal.date(from: $0) })
                }
                continuation.resume(returning: items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    /// Saves the reminder; with a due time it also gets an alert then.
    func add(_ draft: ReminderDraft, calendar cal: Calendar) throws {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted else { throw NaviError.other("Navi needs Reminders access to add this.") }
        let list = draft.listID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewReminders()
        guard let list else { throw NaviError.other("No Reminders list to add to — create one in Reminders.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar = list
        if draft.highPriority { reminder.priority = 1 }
        if let due = draft.due {
            reminder.dueDateComponents = cal.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
            if let rule = Self.recurrenceRule(for: draft.repeatRule) { reminder.addRecurrenceRule(rule) }
        }
        try store.save(reminder, commit: true)
    }

    static func recurrenceRule(for rule: ReminderRequest.Repeat) -> EKRecurrenceRule? {
        switch rule {
        case .never:
            return nil
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .weekly(let day):
            guard let day, let weekday = EKWeekday(rawValue: day) else {
                return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
            }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(weekday)],
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        case .weekdays:
            let days = (2...6).compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        }
    }

    static func openRemindersApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }
}
