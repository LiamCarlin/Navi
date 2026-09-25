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

    // MARK: Navi Cloud (account transport)
    /// Base URL of the Navi Cloud proxy. `defaults write com.liamcarlin.navi cloudBaseURL http://127.0.0.1:8787`
    /// points a build at a mock server (see scripts/dev/mock-cloud.py).
    @Published var cloudBaseURL: String { didSet { d.set(cloudBaseURL, forKey: CloudTransport.baseURLKey) } }
    /// Route model calls through Navi Cloud when signed in. Off ⇒ developer
    /// mode: the vendor keys in AI Providers are used directly.
    @Published var useCloud: Bool { didSet { d.set(useCloud, forKey: CloudTransport.useCloudKey); NotificationCenter.default.post(name: .naviAccountChanged, object: nil) } }

    // MARK: AI
    @Published var jevModel: String { didSet { d.set(jevModel, forKey: "jevModel") } }
    /// Which transport reaches Jev: TypeSafe's API directly or Vercel AI Gateway.
    @Published var jevProvider: JevProvider { didSet { d.set(jevProvider.rawValue, forKey: "jevProvider") } }
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
    /// Who decides each computer-use step: Jev from the accessibility tree (Claude only as fallback) or Claude's vision loop.
    @Published var agentDriver: AgentDriver { didSet { d.set(agentDriver.rawValue, forKey: "agentDriver") } }
    /// Below this operation confidence the Jev-first driver hands the step to Claude.
    @Published var agentJevConfidenceThreshold: Double { didSet { d.set(agentJevConfidenceThreshold, forKey: "agentJevConfidenceThreshold") } }
    /// Maximum bounded Claude turns per Jev-first run.
    @Published var agentMaxClaudeFallbacks: Int { didSet { d.set(agentMaxClaudeFallbacks, forKey: "agentMaxClaudeFallbacks") } }
    /// Drive the target app behind the user's windows: input is posted to that
    /// process, screenshots capture only its window, nothing is ever activated —
    /// so the user can keep working while a task runs.
    @Published var agentRunInBackground: Bool { didSet { d.set(agentRunInBackground, forKey: "agentRunInBackground") } }
    /// Background mode: once a task that *makes* something (a note, an event, a
    /// doc — not a lookup) completes, bring its app or browser tab to the front
    /// so the result is not left hidden behind the user's windows.
    @Published var agentRevealWhenDone: Bool { didSet { d.set(agentRevealWhenDone, forKey: "agentRevealWhenDone") } }
    /// Plan tasks the way the user does them: screen memory says which apps and
    /// sites they use for what (`UserHabits`). Read via UserDefaults off the main actor.
    @Published var agentUsesScreenHabits: Bool { didSet { d.set(agentUsesScreenHabits, forKey: "agentUsesScreenHabits") } }
    /// Press Chrome's per-connection "Allow remote debugging?" sheet for Browser Harness
    /// daemons (Navi's and dev tools') — `ChromeDebugApproval` — instead of asking every reconnect.
    @Published var agentAutoApproveChrome: Bool { didSet { d.set(agentAutoApproveChrome, forKey: "agentAutoApproveChrome") } }
    /// Close Chrome's "controlled by automated test software" bar whenever it appears.
    @Published var agentHideChromeAutomationBar: Bool { didSet { d.set(agentHideChromeAutomationBar, forKey: "agentHideChromeAutomationBar") } }

    // MARK: Voice control (the notch island)
    /// BCP-47 locale for on-device recognition; "" ⇒ the system locale.
    @Published var voiceLocale: String { didSet { d.set(voiceLocale, forKey: "voiceLocale") } }
    /// Voice tasks bring the app forward and use the real cursor (you watch it
    /// happen); off ⇒ the typed-task background mode.
    @Published var voiceBringsAppsForward: Bool { didSet { d.set(voiceBringsAppsForward, forKey: "voiceBringsAppsForward") } }
    @Published var voiceSounds: Bool { didSet { d.set(voiceSounds, forKey: "voiceSounds") } }
    /// Debounce after the last recognized word before Jev is asked whether the
    /// clause is complete. Lower = snappier, more false starts.
    @Published var voiceReactionMs: Int { didSet { d.set(voiceReactionMs, forKey: "voiceReactionMs") } }
    /// A global shortcut that starts / stops voice control from anywhere (default ⌥Space),
    /// so talking to Navi never needs the panel first.
    @Published var voiceHotKeyEnabled: Bool { didSet { d.set(voiceHotKeyEnabled, forKey: "voiceHotKeyEnabled"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    @Published var voiceHotKeyCode: UInt32 { didSet { d.set(Int(voiceHotKeyCode), forKey: "voiceHotKeyCode"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    @Published var voiceHotKeyModifiers: UInt32 { didSet { d.set(Int(voiceHotKeyModifiers), forKey: "voiceHotKeyModifiers"); NotificationCenter.default.post(name: .naviSettingsChanged, object: nil) } }
    /// Start listening as soon as Navi launches (hands-free from login).
    @Published var voiceStartsAtLaunch: Bool { didSet { d.set(voiceStartsAtLaunch, forKey: "voiceStartsAtLaunch") } }

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
            CloudTransport.baseURLKey: CloudTransport.defaultBaseURL,
            CloudTransport.useCloudKey: true,
            "jevModel": "jev-latest",
            "jevProvider": JevProvider.auto.rawValue,
            "answerModel": "claude-sonnet-5",
            "agentModel": "claude-sonnet-5",
            "digestProvider": DigestProvider.auto.rawValue,
            "jevConfidenceThreshold": 0.55,
            "agentApprovalMode": ApprovalMode.askForRisky.rawValue,
            "agentMaxSteps": 40,
            "agentShowLiveOverlay": true,
            "agentDriver": AgentDriver.jevFirst.rawValue,
            "agentJevConfidenceThreshold": 0.5,
            "agentMaxClaudeFallbacks": 6,
            "agentRunInBackground": true,
            "agentRevealWhenDone": true,
            "agentUsesScreenHabits": true,
            "agentAutoApproveChrome": true,
            "agentHideChromeAutomationBar": true,
            "voiceLocale": "",
            "voiceBringsAppsForward": true,
            "voiceSounds": true,
            "voiceReactionMs": 150,
            "voiceHotKeyEnabled": true,
            "voiceHotKeyCode": 49,       // Space
            "voiceHotKeyModifiers": 2048, // optionKey (Carbon)
            "voiceStartsAtLaunch": false,
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
        cloudBaseURL = d.string(forKey: CloudTransport.baseURLKey) ?? CloudTransport.defaultBaseURL
        useCloud = d.bool(forKey: CloudTransport.useCloudKey)
        jevModel = d.string(forKey: "jevModel") ?? "jev-latest"
        jevProvider = JevProvider(rawValue: d.string(forKey: "jevProvider") ?? "") ?? .auto
        answerModel = d.string(forKey: "answerModel") ?? "claude-sonnet-5"
        agentModel = d.string(forKey: "agentModel") ?? "claude-sonnet-5"
        digestProvider = DigestProvider(rawValue: d.string(forKey: "digestProvider") ?? "") ?? .auto
        jevConfidenceThreshold = d.double(forKey: "jevConfidenceThreshold")
        agentApprovalMode = ApprovalMode(rawValue: d.string(forKey: "agentApprovalMode") ?? "") ?? .askForRisky
        agentMaxSteps = d.integer(forKey: "agentMaxSteps")
        agentShowLiveOverlay = d.bool(forKey: "agentShowLiveOverlay")
        agentDriver = AgentDriver(rawValue: d.string(forKey: "agentDriver") ?? "") ?? .jevFirst
        agentJevConfidenceThreshold = d.double(forKey: "agentJevConfidenceThreshold")
        agentMaxClaudeFallbacks = d.integer(forKey: "agentMaxClaudeFallbacks")
        agentRunInBackground = d.bool(forKey: "agentRunInBackground")
        agentRevealWhenDone = d.bool(forKey: "agentRevealWhenDone")
        agentUsesScreenHabits = d.bool(forKey: "agentUsesScreenHabits")
        agentAutoApproveChrome = d.bool(forKey: "agentAutoApproveChrome")
        agentHideChromeAutomationBar = d.bool(forKey: "agentHideChromeAutomationBar")
        voiceLocale = d.string(forKey: "voiceLocale") ?? ""
        voiceBringsAppsForward = d.bool(forKey: "voiceBringsAppsForward")
        voiceSounds = d.bool(forKey: "voiceSounds")
        voiceReactionMs = d.integer(forKey: "voiceReactionMs")
        voiceHotKeyEnabled = d.bool(forKey: "voiceHotKeyEnabled")
        voiceHotKeyCode = UInt32(d.integer(forKey: "voiceHotKeyCode"))
        voiceHotKeyModifiers = UInt32(d.integer(forKey: "voiceHotKeyModifiers"))
        voiceStartsAtLaunch = d.bool(forKey: "voiceStartsAtLaunch")
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

        // 2026-09-19: default model moved from Opus 5 to Sonnet 5 (cost). Migrate once.
        if !d.bool(forKey: "migratedDefaultModelToSonnet") {
            if answerModel == "claude-opus-5" { answerModel = "claude-sonnet-5" }
            if agentModel == "claude-opus-5" { agentModel = "claude-sonnet-5" }
            d.set(true, forKey: "migratedDefaultModelToSonnet")
        }
    }

    /// Claude models offered in pickers. Sonnet 5 is the default (2.5× cheaper than Opus 5).
    static let claudeModels: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Claude Sonnet 5 — default, $2 / $10 per MTok"),
        ("claude-opus-5", "Claude Opus 5 — most capable, $5 / $25 per MTok"),
        ("claude-haiku-4-5", "Claude Haiku 4.5 — fastest, $1 / $5 per MTok"),
    ]

    // MARK: Auto mode

    /// **Auto mode**: Navi acts on its own. Jev decides every step from what is
    /// on screen (native apps and any browser alike), Claude is consulted only
    /// when Jev is stuck, and nothing pauses for approval except actions that
    /// cannot be undone — sending, paying, deleting. Off ⇒ every action asks
    /// first. It is a preset over the agent settings, so the two stay in step.
    var autoMode: Bool {
        get { agentDriver == .jevFirst && agentApprovalMode != .alwaysAsk }
        set {
            if newValue {
                agentDriver = .jevFirst
                if agentApprovalMode == .alwaysAsk { agentApprovalMode = .askForRisky }
                if agentJevConfidenceThreshold > 0.5 { agentJevConfidenceThreshold = 0.5 }
            } else {
                agentApprovalMode = .alwaysAsk
            }
            objectWillChange.send()
        }
    }

    // MARK: Derived

    /// Hidden Developer section + vendor details: `defaults write com.liamcarlin.navi developerMode -bool YES`.
    nonisolated static var developerMode: Bool { UserDefaults.standard.bool(forKey: "developerMode") }

    /// True when the selected Jev transport has a key.
    var hasJevKey: Bool { JevClient.resolveTransport(preference: jevProvider) != nil }
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

enum JevProvider: String, CaseIterable, Identifiable {
    /// TypeSafe key if present, otherwise Vercel AI Gateway key.
    case auto, typesafe, vercelGateway
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (TypeSafe, then Vercel)"
        case .typesafe: return "TypeSafe API (direct)"
        case .vercelGateway: return "Vercel AI Gateway"
        }
    }
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

enum AgentDriver: String, CaseIterable, Identifiable {
    /// Jev decides every step from the accessibility tree (~100 ms); Claude only sees the screen when Jev isn't confident.
    case jevFirst
    /// The original Claude computer-use loop (screenshots every step); Jev only gates safety.
    case claudeOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jevFirst: return "Jev-first"
        case .claudeOnly: return "Claude-only"
        }
    }
    var detail: String {
        switch self {
        case .jevFirst: return "Jev decides every step from the accessibility tree (~100 ms); Claude only sees the screen when Jev isn't confident."
        case .claudeOnly: return "Claude looks at a screenshot before every action and drives the whole task; Jev only gates risky steps."
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
