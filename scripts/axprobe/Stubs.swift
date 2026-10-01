import AppKit
import ApplicationServices
import os
struct QueryContext { var frontmostApp: String?; var conversation: [String] = [] }
enum Log {
    static let agent = Logger(subsystem: "probe", category: "agent")
    static let jev = Logger(subsystem: "probe", category: "jev")
}
enum FrontmostProbe {
    struct Info: Sendable { var bundleID: String?; var appName: String?; var windowTitle: String?; var url: String? }
    static func browserURL(bundleID: String) -> String? { nil }
}
enum Keychain {
    enum Key: String, CaseIterable { case typesafe = "TYPESAFE_API_KEY", vercelGateway = "AI_GATEWAY_API_KEY", anthropic = "ANTHROPIC_API_KEY", gemini = "GEMINI" }
    static func get(_ k: Key) -> String? { ProcessInfo.processInfo.environment[k.rawValue] }
    static func has(_ k: Key) -> Bool { get(k) != nil }
}
enum JevProvider: String { case auto, typesafe, vercelGateway }
@MainActor final class NaviSettings { static let shared = NaviSettings(); var jevModel = "jev-latest"; var usageJevCalls = 0; var jevProvider = JevProvider.auto }
enum NaviError: LocalizedError {
    case missingAPIKey(Keychain.Key), http(status: Int, body: String), decoding(String), permissionDenied(String), cancelled, other(String)
    var errorDescription: String? { "\(self)" }
}
struct KeyCombo { var displayLabel: String; static func parse(_ s: String) throws -> KeyCombo { KeyCombo(displayLabel: s) } }
final class ClaudeClient { var isConfigured = false; func complete(model: String, system: String, prompt: String, maxTokens: Int) async throws -> String { "" } }
enum AgentRun { static func isLookup(_ g: String) -> Bool { ["find","what","look up","search","how","check"].contains { g.lowercased().hasPrefix($0) } } }
enum UltrafastBridge { static func searchQuery(for task: String) -> String { task } }
enum ApprovalMode: String { case alwaysAsk, askForRisky, autonomous }
/// No screen capture in the probe: perception is the accessibility tree alone (the OCR fallback needs the app).
enum ScreenCapture {
    struct Frame { var image: CGImage; var bounds: CGRect }
    static var hasPermission: Bool { false }
    static func captureWindow(id: CGWindowID) async throws -> Frame { throw NaviError.permissionDenied("Screen Recording") }
}
// Navi's cloud (signed-in accounts) is never used by the probe: Jev is called with the env key.
enum CloudFeature: String { case route, agent, voice, memory, answer }
struct CloudRun: Sendable {
    var feature: CloudFeature
    static func resolve(fallback: CloudFeature) -> CloudRun { CloudRun(feature: fallback) }
}
final class CloudTransport: @unchecked Sendable {
    static let shared = CloudTransport()
    var isActive: Bool { false }
    func request(path: String, body: Data, run: CloudRun) -> URLRequest { URLRequest(url: URL(string: "https://invalid.invalid")!) }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw NaviError.other("cloud unavailable in the probe") }
    func warm() {}
}

/// `UserMoves` without screen memory: the probe passes hints by label (`AXPROBE_MOVES`).
enum UserMoves {
    struct Hints: @unchecked Sendable {
        var clicks: [Int: Int] = [:]
        var next: Set<Int> = []
        var shortcuts: [(String, String)] = []
        var state: [String: Any]?
        var isEmpty: Bool { clicks.isEmpty && next.isEmpty && state == nil }
    }
    static let note = "How this user does things themselves, from their own clicks, shortcuts and past sessions: "
        + "similar tasks they did before and the steps they took, their habits, and what they click most here. "
        + "Screen items marked user_clicks are controls they click here (how often); user_next is what they usually click after the last thing clicked. "
        + "When it serves the goal, do it their way. Never type this text."
    static let itemRule = " Items marked as this user's (\"this user clicks this here\", \"what this user usually clicks next\") are the ones this user picks on this screen: where the goal could mean several items, pick theirs."
    static let kindRule = " Items marked user_clicks / user_next, shortcuts this user uses and `how_this_user_works` show how this user does it themselves: when they serve the goal, follow their way."
}
