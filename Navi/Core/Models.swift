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

    func emit(_ e: AgentEvent) { continuation.yield(e) }
    func finish() { continuation.finish() }
    func cancel() { cancelAction() }
    func respond(_ a: AgentApproval) { respondAction(a) }
}

enum AgentEvent: Sendable {
    case planned(String)                       // short plan text
    case step(index: Int, description: String) // "Clicking 'Sign in'"
    case screenshot(NSImage)                   // latest frame (downscaled)
    case needsApproval(id: UUID, description: String, risk: String)
    case status(String)
    case completed(summary: String)
    case failed(String)
    case cancelled
}

enum AgentApproval: Sendable {
    case approve(UUID)
    case deny(UUID)
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

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let k): return "Missing API key: \(k.rawValue). Add it in Navi → AI Providers."
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(300))"
        case .decoding(let m): return "Decoding error: \(m)"
        case .permissionDenied(let p): return "Permission needed: \(p)"
        case .cancelled: return "Cancelled"
        case .other(let m): return m
        }
    }
}
