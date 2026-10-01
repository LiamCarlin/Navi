import SwiftUI

/// What Navi has done for you this month, counted on this Mac: answers
/// streamed and tasks run from the ⌘Space panel. The counters live in
/// `UserDefaults` and roll over at the start of each month. (Token counts and
/// price estimates are a developer concern — see `TokenUsageSection`.)
enum UsageCounters {
    enum Kind { case answer, task }

    static let answersKey = "usageAnswersThisMonth"
    static let tasksKey = "usageTasksThisMonth"
    static let monthKey = "usageMonth"

    /// "2026-09" — the bucket a date's counts belong to.
    static func month(of date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func record(_ kind: Kind, in defaults: UserDefaults = .standard, now: Date = Date()) {
        rollOverIfNeeded(in: defaults, now: now)
        let key = kind == .answer ? answersKey : tasksKey
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    static func counts(in defaults: UserDefaults = .standard, now: Date = Date()) -> (answers: Int, tasks: Int) {
        rollOverIfNeeded(in: defaults, now: now)
        return (defaults.integer(forKey: answersKey), defaults.integer(forKey: tasksKey))
    }

    static func reset(in defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(0, forKey: answersKey)
        defaults.set(0, forKey: tasksKey)
        defaults.set(month(of: now), forKey: monthKey)
    }

    /// A new month starts both counters at zero.
    static func rollOverIfNeeded(in defaults: UserDefaults, now: Date) {
        if defaults.string(forKey: monthKey) != month(of: now) { reset(in: defaults, now: now) }
    }
}

/// "This month on this Mac: 12 answers · 3 tasks" — shown on the Account
/// page (the Usage page it used to have folded into Account).
struct LocalUsageRow: View {
    @AppStorage(UsageCounters.answersKey) private var answers = 0
    @AppStorage(UsageCounters.tasksKey) private var tasks = 0

    var body: some View {
        LabeledContent {
            Text("\(answers) answer\(answers == 1 ? "" : "s") · \(tasks) task\(tasks == 1 ? "" : "s")")
                .monospacedDigit().foregroundStyle(.secondary)
        } label: {
            Text("This month on this Mac")
        }
        .onAppear { UsageCounters.rollOverIfNeeded(in: .standard, now: Date()) }
    }
}
