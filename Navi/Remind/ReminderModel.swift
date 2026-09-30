import AppKit
import Combine
import Foundation

/// State behind the reminder card that drops down from the ⌘Space bar when
/// the query asks to be reminded of something. Typing keeps updating it; a
/// chip, repeat or list picked on the card sticks until that part of the text
/// changes.
@MainActor
final class ReminderModel: ObservableObject {
    enum Adding: Equatable {
        case idle, adding
        case added(String)
        case failed(String)
    }

    @Published private(set) var request: ReminderRequest
    @Published private(set) var due: Date? = nil
    @Published private(set) var repeatRule: ReminderRequest.Repeat
    @Published private(set) var highPriority: Bool
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var listID: String? = nil
    @Published private(set) var alsoDue: [DueReminder] = []
    @Published private(set) var access: Permissions.State
    @Published private(set) var adding: Adding = .idle

    /// Called once the reminder is saved (toast + close the panel).
    var onAdded: ((String) -> Void)?

    let calendar: Calendar
    private let now: () -> Date
    private let store: ReminderStore
    private var manualDue = false
    private var manualRepeat = false
    private var manualPriority = false
    private var loadTask: Task<Void, Never>?
    private var loadedDay: Date?

    init(request: ReminderRequest, calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         store: ReminderStore = .shared) {
        self.request = request
        self.calendar = calendar
        self.now = now
        self.store = store
        self.repeatRule = request.repeatRule
        self.highPriority = request.highPriority
        self.access = store.status
        self.due = request.resolvedDue(now: now(), calendar: calendar)
        loadLists()
        loadAlsoDue()
    }

    // MARK: Derived

    var title: String { request.title }

    /// The chips: what was typed (when it isn't one of them), then the presets.
    var options: [ReminderPlanner.Option] {
        var presets = ReminderPlanner.options(now: now(), calendar: calendar)
        if let typed = request.resolvedDue(now: now(), calendar: calendar),
           !presets.contains(where: { $0.date == typed }) {
            presets.insert(ReminderPlanner.Option(label: ReminderPlanner.dueLabel(typed, now: now(), calendar: calendar),
                                                  date: typed), at: 0)
        }
        return presets
    }

    var dueLabel: String {
        guard let due else { return "No date" }
        return ReminderPlanner.dueLabel(due, now: now(), calendar: calendar)
    }

    /// "Tomorrow at 5:00 PM · Every Monday"
    var summary: String {
        var parts = [dueLabel]
        if repeatRule != .never { parts.append(repeatRule.label) }
        if highPriority { parts.append("High priority") }
        return parts.joined(separator: " · ")
    }

    var list: ReminderList? { lists.first { $0.id == listID } ?? lists.first }

    var canAdd: Bool {
        !request.title.isEmpty && access == .granted && adding != .adding && !isAdded
    }

    var isAdded: Bool { if case .added = adding { return true }; return false }

    /// The line under the card.
    var status: SchedulerModel.Status {
        switch adding {
        case .adding: return .init(text: "Adding…", symbol: "checklist", tone: .neutral)
        case .added(let text): return .init(text: text, symbol: "checkmark.circle.fill", tone: .good)
        case .failed(let text): return .init(text: text, symbol: "exclamationmark.circle.fill", tone: .warning)
        case .idle: break
        }
        if access != .granted {
            return .init(text: "Allow Reminders access to add this", symbol: "checklist", tone: .neutral)
        }
        if request.title.isEmpty {
            return .init(text: "What should Navi remind you about?", symbol: "info.circle.fill", tone: .neutral)
        }
        if let due, due <= now() {
            return .init(text: "That time has passed — pick another", symbol: "exclamationmark.circle.fill", tone: .warning)
        }
        if repeatRule != .never, due == nil {
            return .init(text: "A repeating reminder needs a date", symbol: "info.circle.fill", tone: .neutral)
        }
        return .init(text: "Adds to \(list?.title ?? "Reminders")", symbol: "checklist", tone: .neutral)
    }

    // MARK: Input

    func update(_ new: ReminderRequest) {
        let old = request
        request = new
        let whenChanged = new.day != old.day || new.time != old.time || new.partOfDay != old.partOfDay
            || new.relativeMinutes != old.relativeMinutes
        if whenChanged { manualDue = false }
        if new.repeatRule != old.repeatRule { manualRepeat = false }
        if new.highPriority != old.highPriority { manualPriority = false }
        if !manualDue { due = new.resolvedDue(now: now(), calendar: calendar) }
        if !manualRepeat { repeatRule = new.repeatRule }
        if !manualPriority { highPriority = new.highPriority }
        if case .failed = adding { adding = .idle }
        loadAlsoDue()
    }

    func select(_ option: ReminderPlanner.Option) {
        due = option.date
        manualDue = true
        loadAlsoDue()
    }

    /// ↑/↓: step through the chips.
    func cycleOption(_ delta: Int) {
        let all = options
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.date == due }
        let next = current.map { ($0 + delta + all.count) % all.count } ?? (delta > 0 ? 0 : all.count - 1)
        select(all[next])
    }

    func setRepeat(_ rule: ReminderRequest.Repeat) {
        repeatRule = rule
        manualRepeat = true
        if rule != .never, due == nil {
            // A repeat needs a start: the next 9 AM (or that weekday's).
            var r = request
            r.repeatRule = rule
            due = r.resolvedDue(now: now(), calendar: calendar)
            loadAlsoDue()
        }
    }

    func togglePriority() {
        highPriority.toggle()
        manualPriority = true
    }

    func selectList(_ id: String) { listID = id }

    // MARK: Permissions

    func requestAccess() {
        if store.status == .denied {
            Opener.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            return
        }
        Task {
            _ = await store.requestAccess()
            access = store.status
            loadLists()
            loadedDay = nil
            loadAlsoDue()
        }
    }

    // MARK: Adding

    func add() {
        guard canAdd else {
            if access != .granted { requestAccess() }
            return
        }
        let draft = ReminderDraft(title: request.title, due: due, repeatRule: due == nil ? .never : repeatRule,
                                  highPriority: highPriority, listID: list?.id)
        adding = .adding
        do {
            try store.add(draft, calendar: calendar)
            let when = due.map { " · \(ReminderPlanner.dueLabel($0, now: now(), calendar: calendar))" } ?? ""
            adding = .added("Added to \(list?.title ?? "Reminders")\(when)")
            onAdded?("Reminder added")
        } catch {
            adding = .failed(error.localizedDescription)
        }
    }

    // MARK: Loading

    private func loadLists() {
        let loaded = store.lists()
        lists = loaded.all
        if listID == nil || !lists.contains(where: { $0.id == listID }) { listID = loaded.defaultID ?? lists.first?.id }
    }

    /// The other open reminders due that day, a moment after the last change.
    private func loadAlsoDue() {
        guard let due else { alsoDue = []; loadedDay = nil; return }
        let day = calendar.startOfDay(for: due)
        guard day != loadedDay else { return }
        loadedDay = day
        loadTask?.cancel()
        let store = self.store
        let calendar = self.calendar
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let items = await store.due(on: day, calendar: calendar)
            guard let self, !Task.isCancelled else { return }
            self.alsoDue = items
        }
    }
}
