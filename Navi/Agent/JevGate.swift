import Foundation

/// Jev "System One" safety gate for the computer-use loop.
///
/// After Claude proposes a turn's actions (and before they run), one Jev call
/// answers four calibrated yes/no questions about structured state. The
/// verdict plus the user's `ApprovalMode` decide whether to proceed, ask for
/// approval, or nudge Claude. When Jev isn't configured (no key / error) a
/// keyword heuristic still catches the prohibited category.
struct JevGate: Sendable {
    let jev: JevClient

    // MARK: Verdict

    enum Source: String, Sendable { case jev, heuristic }

    struct Verdict: Sendable, Equatable {
        var isIrreversible: Double = 0
        var isProhibited: Double = 0
        var taskComplete: Double = 0
        var isStuck: Double = 0
        var source: Source = .heuristic
        /// Keyword that tripped the heuristic, if any.
        var keywordHit: String? = nil
        var latencyMs: Int = 0
    }

    enum Decision: Equatable, Sendable {
        case proceed
        /// Emit `.needsApproval` with this risk text and wait.
        case askApproval(risk: String)
    }

    static let thresholdProhibited = 0.5
    static let thresholdIrreversible = 0.5
    static let thresholdStuck = 0.7

    // MARK: State formatting

    /// Structured state block Jev is trained on (labelled sections, not prose).
    static func formatState(task: String, step: Int, maxSteps: Int, claudeSays: String,
                            proposedActions: [String], recentActions: [String],
                            app: String?, windowTitle: String?) -> String {
        var s = "[TASK] \(task)\n"
        s += "[STEP] \(step) of \(maxSteps)\n"
        s += "[CLAUDE_SAYS] \(claudeSays.isEmpty ? "(none)" : claudeSays)\n"
        s += "[PROPOSED_ACTIONS]\n"
        if proposedActions.isEmpty { s += "(none)\n" }
        for (i, a) in proposedActions.enumerated() { s += "\(i + 1). \(a)\n" }
        s += "[RECENT_ACTIONS]\n"
        if recentActions.isEmpty { s += "(none)\n" }
        for a in recentActions.suffix(6) { s += "- \(a)\n" }
        s += "[SCREEN] app=\(app ?? "unknown") title=\(windowTitle ?? "")"
        return s
    }

    static let questions: [String: JevClient.Question] = [
        "is_irreversible": .noul(instructions: "Executing these actions would send a message/email/post, make a purchase or payment, delete or overwrite data, or otherwise be hard to undo"),
        "is_prohibited": .noul(instructions: "These actions enter a password, 2FA code, payment card or bank details, execute a financial transaction, or change security settings"),
        "task_complete": .noul(instructions: "The task is already fully accomplished"),
        "is_stuck": .noul(instructions: "The agent is repeating the same actions without progress"),
    ]

    // MARK: Heuristic

    /// Word-boundary keyword scan for the prohibited category. Returns the
    /// keyword that matched, or nil.
    static func prohibitedKeyword(in text: String) -> String? {
        let lower = text.lowercased()
        let phrases = ["credit card", "send $", "cvv", "ssn", "password", "passcode", "2fa", "one-time code", "routing number"]
        for p in phrases where lower.contains(p) { return p }
        let words = ["buy", "purchase", "transfer", "checkout", "wire"]
        for w in words {
            if let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: w))\\b"),
               re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return w
            }
        }
        return nil
    }

    // MARK: Evaluate

    /// One Jev call (or the heuristic fallback). Never throws — gating must not
    /// break the loop.
    func evaluate(state: String, heuristicText: String) async -> Verdict {
        var v = Verdict()
        if let hit = Self.prohibitedKeyword(in: heuristicText) {
            v.keywordHit = hit
            v.isProhibited = 1
        }
        guard jev.isConfigured else { return v }
        do {
            let r = try await jev.ask(state: state, questions: Self.questions, cacheable: false)
            v.source = .jev
            v.latencyMs = r.latencyMs
            v.isIrreversible = r["is_irreversible"]?.noul ?? 0
            v.isProhibited = max(v.isProhibited, r["is_prohibited"]?.noul ?? 0)
            v.taskComplete = r["task_complete"]?.noul ?? 0
            v.isStuck = r["is_stuck"]?.noul ?? 0
            Log.agent.debug("Jev gate: irreversible=\(v.isIrreversible, format: .fixed(precision: 2)) prohibited=\(v.isProhibited, format: .fixed(precision: 2)) stuck=\(v.isStuck, format: .fixed(precision: 2)) in \(r.latencyMs)ms")
        } catch {
            Log.agent.error("Jev gate failed, falling back to heuristic: \(error.localizedDescription)")
        }
        return v
    }

    // MARK: Decide

    /// Combines the verdict with the user's approval mode.
    /// - `readOnlyTurn`: every proposed action only observes (screenshot, zoom…);
    ///   such turns never need approval even in `.alwaysAsk`.
    static func decide(_ v: Verdict, mode: ApprovalMode, readOnlyTurn: Bool) -> Decision {
        if v.isProhibited > thresholdProhibited {
            var risk = "Prohibited category: this may involve credentials, payment details, a financial transaction, or security settings."
            if let k = v.keywordHit { risk += " (matched \"\(k)\")" }
            return .askApproval(risk: risk)
        }
        if readOnlyTurn { return .proceed }
        switch mode {
        case .autonomous:
            return .proceed
        case .alwaysAsk:
            return .askApproval(risk: v.isIrreversible > thresholdIrreversible
                                ? "Likely irreversible (sends, pays, deletes or overwrites something)."
                                : "Approval required for every action (Settings → Agent).")
        case .askForRisky:
            if v.isIrreversible > thresholdIrreversible {
                return .askApproval(risk: "Jev flags this as irreversible (\(Int(v.isIrreversible * 100))%): it may send, pay, delete or overwrite something.")
            }
            return .proceed
        }
    }

    static let stuckNudge = "You appear stuck; take a screenshot and try a different approach."
}
