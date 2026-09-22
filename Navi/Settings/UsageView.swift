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

struct UsageView: View {
    @EnvironmentObject private var settings: NaviSettings
    @AppStorage(UsageCounters.answersKey) private var answers = 0
    @AppStorage(UsageCounters.tasksKey) private var tasks = 0
    @State private var confirmReset = false

    var body: some View {
        FormPage(title: "Usage", subtitle: "What Navi has done for you this month, counted on this Mac.") {
            Section {
                HStack(spacing: 12) {
                    tile("Answers this month", answers, "text.bubble")
                    tile("Tasks this month", tasks, "cursorarrow.motionlines")
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Answers are questions Navi answered in the panel; tasks are things it did for you on your Mac. Counters start over on the first of each month.")
            }

            Section {
                HStack {
                    Button("Reset counters", role: .destructive) { confirmReset = true }
                    Spacer()
                }
                .confirmationDialog("Reset the usage counters?", isPresented: $confirmReset) {
                    Button("Reset", role: .destructive) {
                        UsageCounters.reset()
                        settings.usageJevCalls = 0
                        settings.usageClaudeInputTokens = 0
                        settings.usageClaudeOutputTokens = 0
                        settings.usageDigestFrames = 0
                    }
                }
            }
        }
        .onAppear { UsageCounters.rollOverIfNeeded(in: .standard, now: Date()) }
    }

    private func tile(_ label: String, _ value: Int, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.tokens(value)).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
