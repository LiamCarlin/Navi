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
