import Foundation

/// Where a multi-step task stands, as every model call reads it: the steps done (and what each
/// produced), the step under way with the visible evidence that completes it, the steps still
/// to come. Jev's `done` then means "this step's evidence is on screen", not "the task feels
/// finished"; the writer judges the same evidence; and a stall re-plans from here instead of
/// retrying a stale step (bench 2026-11-01: tier-5 tasks 0/10, Navi's own "completed" wrong
/// 20 of 45 times — each step ran to its own `done` with nothing to check it against).
struct PlanLedger: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Status: Equatable, Sendable { case done(produced: String?), current, pending }
        var goal: String
        /// "browser", or the app's name.
        var place: String
        var doneWhen: String?
        var mustNot: String?
        var status: Status
    }

    var task: String
    var entries: [Entry]
    /// How many times the remaining steps were re-planned from the screen.
    var replans = 0

    static let maxProduced = 200
    /// `step_done` below this does not end a step on Jev's word alone.
    static let stepDoneThreshold = 0.7

    init(task: String, plan: TaskPlanner.Plan, current: Int, results: [Int: String], replans: Int = 0) {
        self.task = task
        self.replans = replans
        entries = plan.steps.enumerated().map { i, s in
            let status: Entry.Status = i < current ? .done(produced: results[i].map { String($0.prefix(Self.maxProduced)) }) : (i == current ? .current : .pending)
            return Entry(goal: s.goal, place: s.surface == .browser ? "browser" : (s.app ?? "app"), doneWhen: s.doneWhen, mustNot: s.mustNot, status: status)
        }
    }

    var current: Entry? { entries.first { $0.status == .current } }
    var currentDoneWhen: String? { current?.doneWhen.flatMap { $0.isEmpty ? nil : $0 } }
    var currentMustNot: String? { current?.mustNot.flatMap { $0.isEmpty ? nil : $0 } }
    var isMultiStep: Bool { entries.count > 1 }

    /// One line per step: "✓ 1. Find the forecast (browser) — produced: 72°F and sunny",
    /// "→ 2. Text Bella … (Messages) — done when: the message shows as the newest bubble", "3. …".
    var lines: [String] {
        entries.enumerated().map { i, e in
            var line: String
            switch e.status {
            case .done(let produced):
                line = "✓ \(i + 1). \(e.goal) (\(e.place))"
                if let p = produced, !p.isEmpty { line += " — produced: \(p)" }
            case .current:
                line = "→ \(i + 1). \(e.goal) (\(e.place))"
                if let d = e.doneWhen, !d.isEmpty { line += " — done when: \(d)" }
            case .pending:
                line = "\(i + 1). \(e.goal) (\(e.place))"
            }
            return line
        }
    }

    /// `state.plan` for Jev and the writer. nil for a one-step plan with nothing to check: the
    /// goal alone says it.
    var state: [String: Any]? {
        guard isMultiStep || currentDoneWhen != nil || currentMustNot != nil else { return nil }
        var s: [String: Any] = ["whole_task": task, "steps": lines]
        if let d = currentDoneWhen { s["current_step_done_when"] = d }
        if let m = currentMustNot { s["current_step_must_not"] = m }
        return s
    }

    /// Said on the `kind` question while a plan is in the state.
    static let kindRule = " The state's `plan` is the whole task's plan: the step marked → is this goal; steps marked ✓ are done (never redo them, their findings are in the state); later steps are not yours yet. 'done' means this step's current_step_done_when is visible on screen now, not that the whole task feels finished; current_step_must_not is a wrong path."

    /// The `step_done` noul's wording for a step with evidence.
    static func stepDoneQuestion(_ doneWhen: String) -> String {
        "The screen now shows this step's completion evidence: \(doneWhen)"
    }

    /// Whether Jev's own `done` may end the step unread: a step with evidence needs `step_done`
    /// at the threshold; one without is judged as before.
    static func acceptsDone(doneWhen: String?, stepDone: Double?) -> Bool {
        guard doneWhen != nil else { return true }
        return (stepDone ?? 0) >= stepDoneThreshold
    }

    /// What the re-planner needs: the steps done with their findings, the step that failed and why.
    func replanSection(failure: String, verdict: RunVerdict?) -> [String: Any] {
        var done: [[String: Any]] = []
        var failed: [String: Any] = [:]
        for (i, e) in entries.enumerated() {
            switch e.status {
            case .done(let produced):
                var d: [String: Any] = ["step": i + 1, "goal": e.goal, "place": e.place]
                if let p = produced, !p.isEmpty { d["produced"] = p }
                done.append(d)
            case .current:
                failed = ["step": i + 1, "goal": e.goal, "place": e.place, "what_happened": String(failure.prefix(400))]
                if let v = verdict { failed["verdict"] = v.rawValue }
                if let d = e.doneWhen { failed["was_to_end_when"] = d }
            case .pending: break
            }
        }
        return ["steps_done": done, "step_that_failed": failed, "steps_that_were_still_planned": entries.filter { $0.status == .pending }.map(\.goal)]
    }
}
