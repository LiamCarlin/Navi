import Foundation

/// System Two steps in once when System One keeps failing.
///
/// After a few ineffective actions in a step (nothing changed on screen, the
/// same element clicked again and again, action errors, or Jev answering
/// BLOCKED), Claude gets the goal, the screen (screenshot when available),
/// the element table Jev sees and the recent actions with their effects. It
/// does NOT take over: it diagnoses why Jev is failing and writes short
/// guidance that rides along in every later Jev request (`guidance` in the
/// state and in each question's instructions), plus optionally the one
/// concrete next action. This happens once per step; if Jev is still
/// failing afterwards the step fails with Claude's diagnosis.
enum JevCoach {
    /// Ineffective actions before Claude is asked.
    static let failuresBeforeCoaching = 3
    /// Consults per step: one per screen (app + window), this many in all.
    static let maxCoachings = 3

    struct Advice: Equatable, Sendable {
        var diagnosis: String
        var guidance: String
        /// Optional concrete first action: operation + target (element index, key combo, …).
        var nextOperation: String?
        var nextTarget: String?
    }

    static let systemPrompt = """
    You are the supervisor of a fast, non-generative decision model ("Jev") that drives a computer by choosing ONE operation per step from an accessibility/DOM element table: CLICK an element index, TYPE_TEXT into an element index, SELECT an option, KEY a shortcut, SCROLL_UP/DOWN, WAIT, DONE, BLOCKED (and on macOS: OPEN_APP, OPEN_URL). Jev cannot see pixels, cannot read instructions that are not in its state, and picks the most plausible element from labels and roles.

    Jev is failing at the current goal. You see the goal, the screen, the element table Jev sees (with indexes), the app's playbook when Navi has one (`screen.playbook`: how the app works, its shortcuts, recipes — prefer its keyboard shortcuts and steps in your guidance), and the recent actions with whether each one changed anything. Work out WHY it is failing — e.g. clicking a label instead of the control, the control it needs is not in the table (needs scrolling, a menu, a keyboard shortcut, or a different app/page), a dialog or autocomplete is in the way, it keeps re-clicking the same thing, the goal is already satisfied, or the goal cannot be done here.

    Reply ONLY with JSON:
    {"diagnosis": "one or two sentences on what is going wrong",
     "guidance": "2–5 short imperative lines Jev should follow from now on, naming element indexes and exact labels from the table when relevant, and what to stop doing",
     "next_operation": "CLICK|TYPE_TEXT|SELECT|KEY|SCROLL_UP|SCROLL_DOWN|WAIT|OPEN_APP|OPEN_URL|DONE|BLOCKED" (optional, only if you are sure of the single best next action),
     "next_target": "element index / key combo / app name / url for next_operation" (optional)}
    Never invent element indexes that are not in the table. Never include credentials or payment details. If the goal is impossible or unsafe here, say so in the diagnosis and use "next_operation": "BLOCKED".
    """

    /// The text part of the prompt; the screenshot (if any) goes alongside as an image block.
    static func prompt(goal: String, screen: [String: Any], history: [[String: Any]], failureSummary: String) -> String {
        let state: [String: Any] = ["goal": goal, "why_asked": failureSummary, "screen": screen, "recent_actions": history]
        let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses the reply. nil ⇒ unusable (the caller then fails the step).
    static func parse(_ raw: String) -> Advice? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !s.hasPrefix("{"), let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let guidance = (obj["guidance"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !guidance.isEmpty else { return nil }
        let diagnosis = (obj["diagnosis"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var advice = Advice(diagnosis: diagnosis.isEmpty ? "Jev kept choosing actions that had no effect" : diagnosis,
                            guidance: String(guidance.prefix(1200)))
        if let op = (obj["next_operation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !op.isEmpty {
            advice.nextOperation = op
            if let t = obj["next_target"] { advice.nextTarget = String(describing: t).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return advice
    }

    /// One Claude call (the agent model, vision when a screenshot is given).
    static func ask(claude: ClaudeClient, model: String, goal: String, screen: [String: Any], history: [[String: Any]],
                    failureSummary: String, screenshotPNG: Data?) async throws -> (Advice?, Int) {
        let text = prompt(goal: goal, screen: screen, history: history, failureSummary: failureSummary)
        let start = Date()
        let reply: String
        if let png = screenshotPNG {
            reply = try await claude.describeImage(model: model, prompt: text, imageData: png, mediaType: "image/png",
                                                   system: systemPrompt, maxTokens: 700)
        } else {
            reply = try await claude.complete(model: model, system: systemPrompt, prompt: text, maxTokens: 700, effort: "medium")
        }
        let advice = parse(reply)
        if advice == nil { Log.agent.warning("JevCoach: unparseable reply: \(reply.prefix(200), privacy: .public)") }
        return (advice, Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: Failure tracking (pure, testable)

    /// Counts ineffective actions within one step. Reset by an action that
    /// visibly changed something and differs from the previous one.
    struct FailureTracker: Equatable, Sendable {
        private(set) var failures = 0
        private(set) var lastAction: String?
        private(set) var reasons: [String] = []

        /// Records an executed action. `changed` nil ⇒ unknown (counts as a change).
        mutating func record(action: String, changed: Bool?, error: String?) {
            let repeated = action == lastAction
            lastAction = action
            if let error {
                failures += 1; reasons.append("‘\(action)’ failed: \(error)")
            } else if changed == false {
                failures += 1; reasons.append("‘\(action)’ changed nothing")
            } else if repeated {
                failures += 1; reasons.append("‘\(action)’ repeated")
            } else {
                failures = 0; reasons.removeAll()
            }
        }

        /// Jev itself gave up (BLOCKED) — counts as a failure on its own.
        mutating func recordBlocked(_ reason: String) {
            failures += 1; reasons.append(reason)
        }

        var shouldCoach: Bool { failures >= JevCoach.failuresBeforeCoaching }
        var summary: String { reasons.suffix(4).joined(separator: "; ") }

        mutating func reset() { failures = 0; reasons.removeAll(); lastAction = nil }
    }
}
