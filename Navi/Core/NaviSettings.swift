import Foundation
import SwiftUI
import Combine

/// All user-facing settings. Backed by UserDefaults (suite: app default) so
/// both the panel and the settings window observe the same values. API keys
/// live in `Keychain`, not here.
@MainActor
final class NaviSettings: ObservableObject {
    static let shared = NaviSettings()

    private let d = UserDefaults.standard

    // MARK: General
    @Published var isFirstLaunch: Bool { didSet { d.set(isFirstLaunch, forKey: "isFirstLaunch") } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    /// Hotkey: Carbon key code + modifier flags. Default ⌘Space (kVK_Space = 49).
    @Published var hotKeyCode: UInt32 { didSet { d.set(Int(hotKeyCode), forKey: "hotKeyCode"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    @Published var hotKeyModifiers: UInt32 { didSet { d.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }

    // MARK: AI
    @Published var jevModel: String { didSet { d.set(jevModel, forKey: "jevModel") } }
    @Published var answerModel: String { didSet { d.set(answerModel, forKey: "answerModel") } }
    @Published var agentModel: String { didSet { d.set(agentModel, forKey: "agentModel") } }
    @Published var digestProvider: DigestProvider { didSet { d.set(digestProvider.rawValue, forKey: "digestProvider") } }
    /// When Jev's confidence for an intent is below this, Navi shows both the
    /// quick match and an "Ask Navi" row instead of committing.
    @Published var jevConfidenceThreshold: Double { didSet { d.set(jevConfidenceThreshold, forKey: "jevConfidenceThreshold") } }

    // MARK: Agent (computer use)
    @Published var agentApprovalMode: ApprovalMode { didSet { d.set(agentApprovalMode.rawValue, forKey: "agentApprovalMode") } }
    @Published var agentMaxSteps: Int { didSet { d.set(agentMaxSteps, forKey: "agentMaxSteps") } }
    @Published var agentShowLiveOverlay: Bool { didSet { d.set(agentShowLiveOverlay, forKey: "agentShowLiveOverlay") } }

    // MARK: Memory (screen capture → Obsidian)
    @Published var memoryCaptureEnabled: Bool { didSet { d.set(memoryCaptureEnabled, forKey: "memoryCaptureEnabled"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    @Published var memoryCaptureIntervalSeconds: Int { didSet { d.set(memoryCaptureIntervalSeconds, forKey: "memoryCaptureIntervalSeconds") } }
    @Published var memoryDigestIntervalMinutes: Int { didSet { d.set(memoryDigestIntervalMinutes, forKey: "memoryDigestIntervalMinutes") } }
    @Published var memoryRetentionDays: Int { didSet { d.set(memoryRetentionDays, forKey: "memoryRetentionDays") } }
    @Published var memoryVaultPath: String { didSet { d.set(memoryVaultPath, forKey: "memoryVaultPath") } }
    @Published var memoryExcludedBundleIDs: [String] { didSet { d.set(memoryExcludedBundleIDs, forKey: "memoryExcludedBundleIDs") } }
    @Published var memoryKeepScreenshots: Bool { didSet { d.set(memoryKeepScreenshots, forKey: "memoryKeepScreenshots") } }
    @Published var memoryPausedUntil: Date? { didSet { d.set(memoryPausedUntil, forKey: "memoryPausedUntil") } }

    // MARK: Usage / cost tracking (rough, local only)
    @Published var usageJevCalls: Int { didSet { d.set(usageJevCalls, forKey: "usageJevCalls") } }
    @Published var usageClaudeInputTokens: Int { didSet { d.set(usageClaudeInputTokens, forKey: "usageClaudeInputTokens") } }
    @Published var usageClaudeOutputTokens: Int { didSet { d.set(usageClaudeOutputTokens, forKey: "usageClaudeOutputTokens") } }
    @Published var usageDigestFrames: Int { didSet { d.set(usageDigestFrames, forKey: "usageDigestFrames") } }

    private init() {
        d.register(defaults: [
            "isFirstLaunch": true,
            "launchAtLogin": false,
            "hotKeyCode": 49,           // Space
            "hotKeyModifiers": 256,     // cmdKey (Carbon)
            "appearance": Appearance.system.rawValue,
            "jevModel": "jev-latest",
            "answerModel": "claude-opus-5",
            "agentModel": "claude-opus-5",
            "digestProvider": DigestProvider.auto.rawValue,
            "jevConfidenceThreshold": 0.55,
            "agentApprovalMode": ApprovalMode.askForRisky.rawValue,
            "agentMaxSteps": 40,
            "agentShowLiveOverlay": true,
            "memoryCaptureEnabled": false,
            "memoryCaptureIntervalSeconds": 30,
            "memoryDigestIntervalMinutes": 10,
            "memoryRetentionDays": 14,
            "memoryVaultPath": NSString(string: "~/Navi Vault").expandingTildeInPath,
            "memoryExcludedBundleIDs": ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"],
            "memoryKeepScreenshots": true,
            "usageJevCalls": 0, "usageClaudeInputTokens": 0, "usageClaudeOutputTokens": 0, "usageDigestFrames": 0,
        ])
        isFirstLaunch = d.bool(forKey: "isFirstLaunch")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        hotKeyCode = UInt32(d.integer(forKey: "hotKeyCode"))
        hotKeyModifiers = UInt32(d.integer(forKey: "hotKeyModifiers"))
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        jevModel = d.string(forKey: "jevModel") ?? "jev-latest"
        answerModel = d.string(forKey: "answerModel") ?? "claude-opus-5"
        agentModel = d.string(forKey: "agentModel") ?? "claude-opus-5"
        digestProvider = DigestProvider(rawValue: d.string(forKey: "digestProvider") ?? "") ?? .auto
        jevConfidenceThreshold = d.double(forKey: "jevConfidenceThreshold")
        agentApprovalMode = ApprovalMode(rawValue: d.string(forKey: "agentApprovalMode") ?? "") ?? .askForRisky
        agentMaxSteps = d.integer(forKey: "agentMaxSteps")
        agentShowLiveOverlay = d.bool(forKey: "agentShowLiveOverlay")
        memoryCaptureEnabled = d.bool(forKey: "memoryCaptureEnabled")
        memoryCaptureIntervalSeconds = d.integer(forKey: "memoryCaptureIntervalSeconds")
        memoryDigestIntervalMinutes = d.integer(forKey: "memoryDigestIntervalMinutes")
        memoryRetentionDays = d.integer(forKey: "memoryRetentionDays")
        memoryVaultPath = d.string(forKey: "memoryVaultPath") ?? ""
        memoryExcludedBundleIDs = d.stringArray(forKey: "memoryExcludedBundleIDs") ?? []
        memoryKeepScreenshots = d.bool(forKey: "memoryKeepScreenshots")
        memoryPausedUntil = d.object(forKey: "memoryPausedUntil") as? Date
        usageJevCalls = d.integer(forKey: "usageJevCalls")
        usageClaudeInputTokens = d.integer(forKey: "usageClaudeInputTokens")
        usageClaudeOutputTokens = d.integer(forKey: "usageClaudeOutputTokens")
        usageDigestFrames = d.integer(forKey: "usageDigestFrames")
    }

    // MARK: Derived

    var hasJevKey: Bool { Keychain.has(.typesafe) }
    var hasClaudeKey: Bool { Keychain.has(.anthropic) }
    var hasGeminiKey: Bool { Keychain.has(.gemini) }

    var memoryIsPaused: Bool {
        if let until = memoryPausedUntil { return until > Date() }
        return false
    }

    /// Application Support directory for Navi's local data (SQLite, frames).
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Navi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

enum DigestProvider: String, CaseIterable, Identifiable {
    /// Gemini Flash-Lite if a key exists (cheapest vision), else Claude Haiku 4.5.
    case auto, gemini, claudeHaiku, localOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (cheapest available)"
        case .gemini: return "Gemini 2.5 Flash-Lite"
        case .claudeHaiku: return "Claude Haiku 4.5"
        case .localOnly: return "Local OCR only (no LLM)"
        }
    }
}

enum ApprovalMode: String, CaseIterable, Identifiable {
    /// Confirm every action the agent takes.
    case alwaysAsk
    /// Only confirm actions Jev flags as risky/irreversible (send, buy, delete…).
    case askForRisky
    /// Never ask (still refuses prohibited categories).
    case autonomous
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alwaysAsk: return "Ask before every action"
        case .askForRisky: return "Ask only for risky actions"
        case .autonomous: return "Autonomous"
        }
    }
}
