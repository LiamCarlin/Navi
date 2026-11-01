import Foundation
import AppKit

// MARK: - Intents (what the user wants)

/// The set of things Navi can do with a query. Jev picks one of these with a
/// calibrated probability; the router turns it into `SearchResult`s.
enum Intent: String, Codable, CaseIterable, Sendable {
    case openApp        // "maps", "chrome", "open slack"
    case openFile       // "budget.xlsx", "that pdf from yesterday"
    case openURL        // "github.com", "https://…"
    case webSearch      // "best ramen in sf"
    case calculate      // "12% of 340", "3 usd in eur", "5pm PST in Tokyo"
    case askQuestion    // "what's the capital of peru", "explain dns"
    case computerTask   // "open chrome, search X and click the first result"
    case recallMemory   // "what was I working on yesterday", "that article about jev"
    case systemCommand  // "sleep", "empty trash", "toggle dark mode", "wifi off"
    case settings       // "navi settings", "change hotkey"

    var displayName: String {
        switch self {
        case .openApp: return "Open app"
        case .openFile: return "Open file"
        case .openURL: return "Open URL"
        case .webSearch: return "Search the web"
        case .calculate: return "Calculate"
        case .askQuestion: return "Ask Navi"
        case .computerTask: return "Do it for me"
        case .recallMemory: return "Recall"
        case .systemCommand: return "System"
        case .settings: return "Settings"
        }
    }

    /// Criteria text sent to Jev as the `choice` options.
    var jevCriteria: String {
        switch self {
        case .openApp: return "Launch or switch to an installed application by name (e.g. 'maps', 'chrome', 'open slack')."
        case .openFile: return "Open or find a specific file or document on this Mac by name or description."
        case .openURL: return "Open a specific website or URL the user typed (domain or full link)."
        case .webSearch: return "Search the web for something (a phrase the user wants results for, not a question to answer)."
        case .calculate: return "Arithmetic, unit or currency conversion, time-zone or date math."
        case .askQuestion: return "A question or request that should be answered in text by an AI assistant."
        case .computerTask: return "A multi-step task that requires controlling apps or the browser on the user's behalf (open X, then do Y)."
        case .recallMemory: return "A question about what the user was doing, reading, or working on earlier on this computer."
        case .systemCommand: return "A macOS system action: sleep, lock, dark mode, volume, wifi, bluetooth, empty trash, screenshot."
        case .settings: return "Change Navi's own settings, hotkey, permissions, or API keys."
        }
    }
}

/// The router's decision for a query.
struct RouteDecision: Sendable {
    var intent: Intent
    var confidence: Double                 // Jev's calibrated confidence (0–1)
    var probabilities: [Intent: Double]
    var isRisky: Bool                      // Jev noul: would this do something irreversible?
    var needsClarification: Bool
    var latencyMs: Int
    var source: Source

    enum Source: String, Sendable { case jev, heuristic, cache }

    static func heuristic(_ intent: Intent, confidence: Double = 0.5) -> RouteDecision {
        RouteDecision(intent: intent, confidence: confidence, probabilities: [intent: confidence],
                      isRisky: false, needsClarification: false, latencyMs: 0, source: .heuristic)
    }
}

// MARK: - Results (what the panel shows)

enum ResultKind: String, Sendable {
    case app, file, url, webSearch, calculation, answer, task, memory, systemCommand, settings, suggestion
}

/// One row in the Navi panel. `perform` runs when the user hits ⏎.
struct SearchResult: Identifiable, Sendable {
    let id: String
    var kind: ResultKind
    var title: String
    var subtitle: String?
    var icon: ResultIcon
    var score: Double = 0            // higher sorts first within the same intent bucket
    var shortcutHint: String? = nil  // e.g. "⏎ Open", "⌘⏎ Reveal"
    var perform: @Sendable @MainActor () async -> ResultOutcome

    init(id: String, kind: ResultKind, title: String, subtitle: String? = nil, icon: ResultIcon,
         score: Double = 0, shortcutHint: String? = nil,
         perform: @escaping @Sendable @MainActor () async -> ResultOutcome) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.icon = icon; self.score = score; self.shortcutHint = shortcutHint; self.perform = perform
    }
}

enum ResultIcon: Sendable {
    case system(String)             // SF Symbol name
    case appBundle(String)          // path to .app (icon fetched lazily)
    case file(String)               // path to file (icon via NSWorkspace)
    case image(NSImage)
}

/// What happens after a result is performed.
enum ResultOutcome: Sendable {
    case dismiss                            // close the panel
    case keepOpen                           // e.g. copied to clipboard, show toast
    case streamAnswer(AsyncThrowingStream<String, Error>)   // show an expanding answer area
    case runAgent(AgentRunHandle)           // show live agent progress
    case showResults([SearchResult])        // replace list (e.g. memory hits)
    case clarify(ClarificationRequest)      // ask a structured follow-up, then re-run the refined query
    case error(String)
}

// MARK: - Clarification

/// A structured follow-up for a request Navi can't act on yet: one short
/// question and a few likely interpretations, each phrased as a complete
/// request Navi can run directly. The panel also offers a free-text answer.
struct ClarificationPrompt: Sendable, Equatable {
    var originalQuery: String
    var question: String
    var options: [String]

    static let maxOptions = 4

    /// The refined query for a chosen option, or for typed free text.
    func refinedQuery(option index: Int) -> String? { options[safe: index] }
    func refinedQuery(typed text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : "\(originalQuery) — \(t)"
    }
}

/// Deferred prompt generation so the panel can show a thinking state while
/// Claude writes the question and options.
struct ClarificationRequest: Sendable {
    let originalQuery: String
    let load: @Sendable () async throws -> ClarificationPrompt
}

// MARK: - Query context

/// Everything the router/agent may want to know about the moment the query was typed.
struct QueryContext: Sendable {
    var frontmostApp: String?           // bundle id
    var frontmostAppName: String?
    var frontmostWindowTitle: String?
    var selectedText: String?           // if we could read it via AX
    var clipboard: String?
    var recentQueries: [String]
    var timestamp: Date
    /// What the user asked just before this and what came of it, most recent
    /// last ("“send him a message saying hi” → Typed ‘hi’ into the message
    /// field; not sent yet"). Voice control fills this so follow-ups like "now
    /// send it" or "the text" resolve; empty for a typed panel query.
    var conversation: [String] = []
    /// The query was spoken (voice control): answers are read off a small
    /// island, so they should be short unless more is asked for.
    var spoken = false
    /// The cloud run every call for this query is billed under (`X-Navi-Run`):
    /// one id per answer / task / voice command, however many model calls it takes.
    var runID = UUID()

    static var empty: QueryContext {
        QueryContext(frontmostApp: nil, frontmostAppName: nil, frontmostWindowTitle: nil,
                     selectedText: nil, clipboard: nil, recentQueries: [], timestamp: Date())
    }
}

// MARK: - Agent (computer use)

/// A live computer-use run. The panel observes `events`; the user can cancel
/// or answer approval requests through `respond`.
final class AgentRunHandle: @unchecked Sendable {
    let id = UUID()
    let task: String
    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let cancelAction: @Sendable () -> Void
    private let respondAction: @Sendable (AgentApproval) -> Void

    init(task: String,
         cancel: @escaping @Sendable () -> Void,
         respond: @escaping @Sendable (AgentApproval) -> Void) {
        self.task = task
        var cont: AsyncStream<AgentEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        self.cancelAction = cancel
        self.respondAction = respond
    }

    /// Optional side channel (run log, overlay); called on the emitting thread.
    var onEmit: (@Sendable (AgentEvent) -> Void)?

    // Integration hook (agent outcome workstream): how the run really ended, set by the agent
    // before it emits `.completed`/`.failed`. `.completed` is emitted only for `.achieved`; a
    // question for the user, a step only they can take, or "not done" arrive as `.failed`
    // with this telling them apart. nil ⇒ the run ended without a typed judgment (cancelled,
    // an error before any judgment).
    private let verdictLock = NSLock()
    private var _verdict: RunVerdict?
    var verdict: RunVerdict? {
        get { verdictLock.lock(); defer { verdictLock.unlock() }; return _verdict }
        set { verdictLock.lock(); _verdict = newValue; verdictLock.unlock() }
    }

    func emit(_ e: AgentEvent) { onEmit?(e); continuation.yield(e) }
    func finish() { continuation.finish() }
    func cancel() { cancelAction() }
    func respond(_ a: AgentApproval) { respondAction(a) }

    // Integration hook (pause-and-ask workstream): the run puts a multiple-choice question to the
    // user and waits (`.needsAnswer`; answered with `respond(.answer(id, reply))`). Set by the agent
    // on every handle it drives; nil reply ⇒ the user stopped the task (or never answered).
    var asker: (@Sendable (AgentQuestion) async -> String?)?
    func ask(_ q: AgentQuestion) async -> String? { await asker?(q) }
}

/// A question a paused run puts to the user: what the screen shows, the question, and the answers
/// they can click (the likeliest first). They may also type their own, or stop the task.
struct AgentQuestion: Sendable, Equatable, Identifiable {
    let id: UUID
    /// The question itself, one short sentence ("Which size do you want?").
    var question: String
    /// What the run saw that led to it ("The menu has the Big Mac in small, medium and large."); may be empty.
    var detail: String
    /// 1–4 clickable answers, the likeliest first.
    var choices: [String]
    /// A typed answer is welcome too (false for "do this on screen, then keep going").
    var allowsOther: Bool

    static let maxChoices = 4
    static let goAheads: Set<String> = ["done", "did", "finished", "continue", "keep", "go", "ok", "okay", "yes", "yeah", "yep",
                                        "ready", "signed", "logged", "proceed", "carry", "next"]

    init(id: UUID = UUID(), question: String, detail: String = "", choices: [String], allowsOther: Bool = true) {
        self.id = id
        self.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = d == self.question ? "" : d
        self.choices = Self.tidy(choices)
        self.allowsOther = allowsOther
    }

    /// Distinct, non-empty, short, at most `maxChoices` — and never an answer naming a date that has
    /// already gone by (bench 2026-11-01: "Did you mean December 5, 2025?" offered on November 1, 2026).
    static func tidy(_ choices: [String], today: Date = Date()) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in choices {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "•-–")))
            guard !t.isEmpty, t.count <= 80, !namesPastDate(t, today: today), seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == maxChoices { break }
        }
        return out
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// The calendar days a short answer names *with a year*: "December 5, 2025", "Fri, Dec 5th 2025",
    /// "5 December 2025", "2025-12-05", "12/05/2025" (US order); a month alone ("December 2025") counts
    /// as its last day. A date without a year names nothing here — it is not known to be past.
    static func datesNamed(in text: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Date] {
        let lower = text.lowercased()
        let ns = lower as NSString
        let month = "(" + monthNumbers.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")\\.?"
        func matches(_ pattern: String) -> [(groups: [String], range: NSRange)] {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return rx.matches(in: lower, range: NSRange(location: 0, length: ns.length)).map { m -> (groups: [String], range: NSRange) in
                let groups = (0..<m.numberOfRanges).map { i -> String in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
                return (groups, m.range)
            }
        }
        func day(_ y: String, _ m: Int?, _ d: String) -> Date? {
            guard let year = Int(y), let m, (1...12).contains(m), let dd = Int(d), dd >= 1 else { return nil }
            var c = DateComponents()
            c.year = year; c.month = m; c.day = dd
            guard let date = calendar.date(from: c), calendar.component(.day, from: date) == dd,
                  calendar.component(.month, from: date) == m else { return nil }
            return date
        }
        var found: [Date] = [], spans: [NSRange] = []
        for m in matches("\\b" + month + "\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b") {
            if let d = day(m.groups[3], monthNumbers[m.groups[1]], m.groups[2]) { found.append(d) }
            spans.append(m.range)
        }
        for m in matches("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?" + month + ",?\\s+(\\d{4})\\b") {
            if let d = day(m.groups[3], monthNumbers[m.groups[2]], m.groups[1]) { found.append(d) }
            spans.append(m.range)
        }
        for m in matches("\\b(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b") {
            if let d = day(m.groups[1], Int(m.groups[2]), m.groups[3]) { found.append(d) }
        }
        for m in matches("\\b(\\d{1,2})/(\\d{1,2})/(\\d{4})\\b") {
            if let d = day(m.groups[3], Int(m.groups[1]), m.groups[2]) { found.append(d) }
        }
        for m in matches("\\b" + month + ",?\\s+(\\d{4})\\b")
        where !spans.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            guard let first = day(m.groups[2], monthNumbers[m.groups[1]], "1"),
                  let days = calendar.range(of: .day, in: .month, for: first)?.count,
                  let last = day(m.groups[2], monthNumbers[m.groups[1]], String(days)) else { continue }
            found.append(last)
        }
        return found
    }

    /// Does this answer name a day before `today`?
    static func namesPastDate(_ text: String, today: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let start = calendar.startOfDay(for: today)
        return datesNamed(in: text, calendar: calendar).contains { $0 < start }
    }

    /// The choice a reply names: its number ("2", "the second one"), or its own words, or a reply
    /// that is mostly one choice's words ("the large one" → "Large"). nil ⇒ the reply is its own answer.
    func choice(matching reply: String) -> String? {
        let r = reply.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !r.isEmpty, !choices.isEmpty else { return nil }
        let ordinals = [["1", "one", "first", "the first", "the first one", "option one", "option 1"],
                        ["2", "two", "second", "the second", "the second one", "option two", "option 2"],
                        ["3", "three", "third", "the third", "the third one", "option three", "option 3"],
                        ["4", "four", "fourth", "the fourth", "the fourth one", "option four", "option 4"]]
        for (i, words) in ordinals.enumerated() where i < choices.count && words.contains(r) { return choices[i] }
        // "Do it, then keep going": any go-ahead picks the one answer ("ok done", "I signed in").
        if choices.count == 1, !allowsOther,
           !Set(r.split(whereSeparator: { !$0.isLetter }).map(String.init)).isDisjoint(with: Self.goAheads) { return choices[0] }
        if let exact = choices.first(where: { $0.lowercased() == r }) { return exact }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                .subtracting(["the", "a", "an", "one", "please", "i", "want", "go", "with", "use", "pick", "that", "it"])
        }
        let said = words(r)
        guard !said.isEmpty else { return nil }
        let scored = choices.map { c -> (String, Int) in (c, words(c).intersection(said).count) }
        let best = scored.max { $0.1 < $1.1 }!
        // One choice names everything the reply says, and no other choice ties with it.
        guard best.1 > 0, best.1 == said.count, scored.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }
}

enum AgentEvent: Sendable {
    case planned(String)                       // short plan text
    case step(index: Int, description: String) // "Clicking 'Sign in'"
    case screenshot(NSImage)                   // latest frame (downscaled)
    case needsApproval(id: UUID, description: String, risk: String)
    /// The run is paused on a question only the user can answer (`AgentRunHandle.ask`).
    case needsAnswer(AgentQuestion)
    case status(String)
    case completed(summary: String)
    case failed(String)
    case cancelled
}

/// A run's typed outcome (`AgentRunHandle.verdict`), from the screen reader's judgment — never
/// from which code path happened to end the run.
enum RunVerdict: String, Sendable, Equatable {
    /// The screen shows every part of the goal done (or the answer to a lookup).
    case achieved
    /// Some of it is done, not all.
    case partial
    /// Not done; the run ran out of moves or budget.
    case notAchieved = "not_achieved"
    /// It cannot be done here (the app/site has no such thing).
    case impossible
    /// Only the user can go on: a question, a login, a payment, an approval.
    case needsUser = "needs_user"

    /// The runner's / writer's spelling ("not achieved", "needs-user"…); unknown ⇒ nil.
    init?(loose: String) {
        let s = loose.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        self.init(rawValue: s == "notachieved" ? "not_achieved" : s == "needsuser" ? "needs_user" : s)
    }

    var isSuccess: Bool { self == .achieved }
}

enum AgentApproval: Sendable {
    case approve(UUID)
    case deny(UUID)
    /// The reply to `AgentEvent.needsAnswer` (a choice's words or the user's own); nil ⇒ stop the task.
    case answer(UUID, String?)
}

// MARK: - Memory

/// A retrieved moment from the screen-memory store.
struct MemoryHit: Identifiable, Sendable {
    let id: Int64
    var timestamp: Date
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var url: String?
    var snippet: String          // matched OCR/summary text
    var thumbnailPath: String?
    var score: Double
}

// MARK: - Errors

enum NaviError: LocalizedError {
    case missingAPIKey(Keychain.Key)
    case http(status: Int, body: String)
    case decoding(String)
    case permissionDenied(String)
    case cancelled
    case other(String)
    /// Navi Cloud 402: the tier's cap for `feature` is used up until `resetsAt`.
    case quotaExceeded(feature: String, tier: String, resetsAt: Date?)
    /// Navi Cloud 403: the tier does not include `feature` (e.g. `recall` on Pro).
    case notEntitled(feature: String, tier: String)
    /// No Navi session (never signed in, or the refresh token was rejected).
    case signedOut
    /// Navi Cloud 426 (or `/v1/me.config.minAppVersion`): this build is too old to be served.
    case upgradeRequired(minAppVersion: String?, downloadURL: URL?)
    /// Navi Cloud 503 `feature_disabled` (or `/v1/me.config.features`): switched off by the operator for now.
    /// `feature` is a `config.features` key ("answers") or a `CloudFeature` raw value ("answer").
    case featureDisabled(feature: String, message: String?)
    /// Navi Cloud 403 `account_disabled`: the account is suspended; no cloud calls until support re-enables it.
    case accountDisabled(message: String?)

    /// What the user can do about an error — the button next to its one-line message.
    enum Recovery: Equatable {
        case signIn
        case upgrade(recall: Bool)
        case updateApp
        case contactSupport
        /// Nothing to press: the message says to try again later.
        case tryLater
    }

    var recovery: Recovery? {
        switch self {
        case .signedOut: return .signIn
        case .missingAPIKey: return NaviSettings.developerMode ? nil : .signIn
        case .quotaExceeded: return .upgrade(recall: false)
        case .notEntitled(let feature, _): return .upgrade(recall: feature.hasPrefix("recall"))
        case .upgradeRequired: return .updateApp
        case .featureDisabled: return .tryLater
        case .accountDisabled: return .contactSupport
        default: return nil
        }
    }

    /// "answers" / "tasks" / "voice control" / "Recall" for a feature name in either spelling.
    static func featureNoun(_ feature: String) -> String {
        let key = CloudFeature(rawValue: feature).flatMap(CloudConfig.Features.key(for:)) ?? feature
        switch key {
        case "answers": return "answers"
        case "tasks": return "tasks"
        case "voice": return "voice control"
        case "recall": return "Recall"
        default: return key.isEmpty ? "this" : key.replacingOccurrences(of: "_", with: " ")
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let k):
            // Without a Navi session the product answer is "sign in"; the key name is a developer detail.
            return NaviSettings.developerMode ? "Missing API key: \(k.rawValue). Add it in Navi → Developer." : "Sign in to Navi to keep going."
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(300))"
        case .decoding(let m): return "Decoding error: \(m)"
        case .permissionDenied(let p): return "Permission needed: \(p)"
        case .cancelled: return "Cancelled"
        case .other(let m): return m
        case .quotaExceeded(let feature, let tier, let resetsAt):
            let noun = CloudFeature(rawValue: feature)?.unitNoun ?? "requests"
            let plan = Tier(rawValue: tier)?.displayName ?? tier.capitalized
            var s = "You've used today's \(noun) on the \(plan.isEmpty ? "current" : plan) plan."
            if let r = resetsAt { s += " Resets \(r.formatted(date: .omitted, time: .shortened))." }
            return s
        case .notEntitled(let feature, let tier):
            let what = CloudFeature(rawValue: feature).map { $0.unitNoun == "Recall" ? "Recall" : $0.unitNoun } ?? feature
            let plan = Tier(rawValue: tier)?.displayName ?? tier.capitalized
            return "\(what.capitalized) isn't included in the \(plan.isEmpty ? "current" : plan) plan."
        case .signedOut:
            return "Sign in to Navi to keep going."
        case .upgradeRequired:
            return "Update Navi to keep using it."
        case .featureDisabled(let feature, let message):
            if let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return m }
            let noun = Self.featureNoun(feature)
            let capitalized = noun.prefix(1).uppercased() + noun.dropFirst()
            return "\(capitalized) \(noun == "voice control" || noun == "Recall" ? "is" : "are") temporarily unavailable. Try again in a little while."
        case .accountDisabled(let message):
            if let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return m }
            return "Your Navi account is disabled. Contact support to sort it out."
        }
    }

    /// True for the errors that come with an Upgrade / Sign in action.
    var isAccountError: Bool {
        switch self {
        case .quotaExceeded, .notEntitled, .signedOut, .upgradeRequired, .featureDisabled, .accountDisabled: return true
        case .missingAPIKey: return !NaviSettings.developerMode
        default: return false
        }
    }
}
