import Foundation

// Port of the stop rules in typesafe_computer_use/runner.py.
//
// Nothing in an action's description says what came of it; only the next capture does. So
// each step keeps a signature of the screen and the loop stops after three actions in a row
// that left the screen as it was, or two in a row that were already taken on the same
// screen earlier in the run (a click that does nothing, or a cycle through two pages). A
// stop hands the run to the writer, whose focus usually frees Jev; a third stall with no
// new page between them is final ("stuck"). The rules err toward running on, never toward
// stopping a run that is making progress.

struct CURunState: Sendable {
    static let maxIdle = 3
    static let maxRepeats = 2
    static let maxStalls = 3
    /// Lines from earlier screens the answer may also be read from.
    static let earlierLines = 600

    enum Outcome: String, Sendable {
        case done
        case nothingHelps = "nothing helps"
        case lowConfidence = "low confidence"
        case stalled
        case stuck
        case stepLimit = "step limit"

        /// The words the writer is handed (runner.py `STOPPED`).
        var told: String {
            switch self {
            case .done: return "the classifier judged the goal already achieved on this screen"
            case .nothingHelps: return "the classifier found nothing on this screen that helps with the goal"
            case .lowConfidence: return "the classifier was not confident enough in any next action"
            case .stalled: return "the last actions changed nothing"
            case .stuck: return "the agent is stuck: its last actions changed nothing, as they did twice before on these same pages, and the focus given each time did not help, so the run ends with this answer"
            case .stepLimit: return "the run used every step it was allowed"
            }
        }
    }

    /// One stop the writer sent Jev back from.
    struct Handoff: Equatable, Sendable {
        var step: Int
        var outcome: Outcome
        var focus: String
        /// Actions taken by then, so a focus that led to none can be told.
        var actions: Int
    }

    var history: [String] = []
    var idle = 0
    var repeats = 0
    var stalls = 0
    var pages = Set<String>()
    var last: CUSignature?
    /// Every screen acted on, with the action (nil for a wait).
    var seen: [(signature: CUSignature, what: String?)] = []
    var guidance = CUGuidance()
    var handoffs: [Handoff] = []

    /// Counts actions that left the screen as it was. False once too many did in a row.
    /// A page the run has not been on before starts the count of stalls again.
    mutating func screenMoved(_ now: CUSignature) -> Bool {
        if pages.insert(now.page).inserted { stalls = 0 }
        if let last { idle = now.same(as: last) ? idle + 1 : 0 }
        last = now
        return idle < Self.maxIdle
    }

    /// Actions already taken on the screen now showing, oldest first.
    func triedHere() -> [String] {
        guard let last else { return [] }
        return seen.compactMap { $0.what != nil && $0.signature.same(as: last) ? $0.what : nil }
    }

    /// Records an action taken on `last`. True when it makes the run stall: the same action on
    /// the same screen led somewhere once, and this is where it led — back here. A wait is
    /// recorded with no action: it is never a repeat and never listed as tried.
    mutating func recordAction(_ what: String, waiting: Bool) -> Bool {
        history.append(what)
        guard let last else { return false }
        if waiting { seen.append((last, nil)); return false }
        repeats = triedHere().contains(what) ? repeats + 1 : 0
        seen.append((last, what))
        return repeats >= Self.maxRepeats
    }

    /// Counts a stall; the third with no new page between them makes the run stuck.
    mutating func countStall(_ outcome: Outcome) -> Outcome {
        guard outcome == .stalled else { return outcome }
        stalls += 1
        return stalls >= Self.maxStalls ? .stuck : .stalled
    }

    /// The distinct screens the run passed through before `final`, oldest first, newest kept
    /// whole when the line budget runs out.
    func earlierScreens(final: CUSignature, budget: Int = earlierLines) -> [[String: Any]] {
        var out: [CUSignature] = []
        var left = budget
        for (sig, _) in seen.reversed() {
            if sig.same(as: final) || out.contains(where: { sig.same(as: $0) }) { continue }
            left -= sig.lines.count
            if left < 0 { break }
            out.append(sig)
        }
        return out.reversed().map { ["app": $0.app, "url": $0.url ?? NSNull(), "text": $0.lines.map(\.text)] }
    }

    var earlierStops: [[String: Any]] {
        handoffs.map { ["after_action": $0.actions, "why": $0.outcome.told, "focus_given": $0.focus] }
    }

    /// After a focus: the stall was under the old focus; the new one starts clean.
    mutating func refocus(_ h: Handoff) {
        handoffs.append(h)
        guidance = guidance.focused(h.focus)
        idle = 0
        repeats = 0
    }
}

/// Requests to each model over a run (calls.py): the classifier's share is the number the
/// design stands on. A task Jev falls on is one the writer had to steer at every turn, and
/// the fix belongs in the state Jev reads, not in more hand-offs.
struct CUCalls: Sendable {
    var jev = 0, jevMs = 0
    var writer = 0, writerMs = 0

    mutating func jev(ms: Int) { jev += 1; jevMs += ms }
    mutating func writer(ms: Int) { writer += 1; writerMs += ms }

    func line(handoffs: Int) -> String {
        let total = max(1, jev + writer)
        func s(_ ms: Int) -> String { String(format: "%.1fs", Double(ms) / 1000) }
        return "calls: jev \(jev) (\(jev * 100 / total)%, \(s(jevMs)))  writer \(writer) (\(writer * 100 / total)%, \(s(writerMs)))  handoffs \(handoffs)"
    }

    var summary: [String: Any] { ["jev": jev, "jev_ms": jevMs, "writer": writer, "writer_ms": writerMs] }
}
