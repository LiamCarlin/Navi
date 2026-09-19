import SwiftUI
import AppKit
import ServiceManagement

/// Home: hero + one status card per thing that must be right for Navi to work.
struct HomeView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var nav = SettingsNavigator.shared
    @StateObject private var perms = PermissionsModel()
    @State private var spotlight = SpotlightShortcutFix.Status()
    @State private var spotlightLoaded = false
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var memoryStatus = MemoryStatus()
    @State private var hasJev = false
    @State private var hasClaude = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Status").font(.title3.weight(.semibold))
                        Spacer()
                        Text(readyLine).font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        cards
                    }
                }
                tips
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task { await poll() }
        .onReceive(NotificationCenter.default.publisher(for: .naviKeysChanged)) { _ in refreshKeys() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 22) {
            NaviMark(size: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text("Navi").font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("Press")
                    KeyCap(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
                    Text("anywhere")
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                Text("Apps, files, math, answers, tasks and what you were doing yesterday — in one field.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                AppDelegate.shared?.togglePanel()
            } label: {
                Label("Try it", systemImage: "sparkles").padding(.horizontal, 6).padding(.vertical, 2)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }

    // MARK: Cards

    @ViewBuilder private var cards: some View {
        StatusCard(title: "Jev API key", detail: hasJev ? "Connected — System One routing is on." : "Missing. Navi falls back to slow heuristics.",
                   level: hasJev ? .ok : .bad, fixTitle: "Add key") { nav.go(.providers) }
        StatusCard(title: "Claude API key", detail: hasClaude ? "Connected — answers and the agent are on." : "Missing. Answers and tasks won't work.",
                   level: hasClaude ? .ok : .bad, fixTitle: "Add key") { nav.go(.providers) }
        StatusCard(title: "Accessibility", detail: perms.accessibility == .granted ? "Granted. The agent can click and type." : "Needed for the agent to click and type.",
                   level: perms.accessibility.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Screen Recording", detail: perms.screenRecording == .granted ? "Granted. Agent and Screen Memory can see the screen." : "Needed for the agent and Screen Memory.",
                   level: perms.screenRecording.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Automation", detail: automationDetail, level: perms.automation.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Spotlight shortcut", detail: spotlightLoaded ? spotlight.summary : "Checking…",
                   level: spotlightLoaded ? spotlight.level : .off, fixTitle: "Fix") { nav.go(.general) }
        StatusCard(title: "Screen Memory", detail: memoryDetail, level: memoryLevel,
                   fixTitle: settings.memoryCaptureEnabled ? "Open" : "Turn on") { nav.go(.memory) }
        StatusCard(title: "Login item", detail: LoginItem.describe(loginStatus), level: LoginItem.level(loginStatus),
                   fixTitle: "Enable") { nav.go(.general) }
    }

    private var automationDetail: String {
        switch perms.automation {
        case .granted: return "Granted. Navi can read the current browser tab."
        case .notDetermined: return "Not requested yet — needed to read browser tabs."
        case .denied: return "Denied. Browser tab context and AppleScript actions are off."
        case .unknown: return "Could not determine (System Events not running?)."
        }
    }

    private var memoryDetail: String {
        if !settings.memoryCaptureEnabled { return "Off. Turn it on to ask \"what was I doing yesterday?\"" }
        if settings.memoryIsPaused, let u = settings.memoryPausedUntil { return "Paused until \(u.formatted(date: .omitted, time: .shortened))." }
        if memoryStatus.isRunning { return "Running · \(memoryStatus.framesToday) frames today · \(memoryStatus.vaultNoteCount) notes." }
        return "Enabled but not running."
    }

    private var memoryLevel: StatusLevel {
        if !settings.memoryCaptureEnabled { return .off }
        if settings.memoryIsPaused { return .warn }
        return memoryStatus.isRunning ? .ok : .warn
    }

    private var readyLine: String {
        var issues = 0
        if !hasJev { issues += 1 }
        if !hasClaude { issues += 1 }
        if perms.accessibility != .granted { issues += 1 }
        if perms.screenRecording != .granted { issues += 1 }
        if spotlightLoaded && spotlight.conflict { issues += 1 }
        return issues == 0 ? "Everything's ready." : "\(issues) thing\(issues == 1 ? "" : "s") to fix"
    }

    // MARK: Tips

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try typing").font(.title3.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 8) {
                tip("maps", "opens Apple Maps — Jev decides in ~100 ms")
                tip("12% of 340", "instant math, currency and time zones")
                tip("why is the sky blue", "streams an answer from Claude")
                tip("open chrome and search for jev", "runs the computer-use agent")
                tip("what was I reading yesterday", "recalls from Screen Memory")
                tip("sleep", "system commands: sleep, lock, dark mode, wifi")
            }
        }
    }

    private func tip(_ q: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(q).font(.callout.monospaced()).foregroundStyle(.primary)
            Text("—").foregroundStyle(.quaternary)
            Text(what).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Polling

    private func refreshKeys() {
        hasJev = Keychain.has(.typesafe)
        hasClaude = Keychain.has(.anthropic)
    }

    private func poll() async {
        refreshKeys()
        spotlight = await SpotlightShortcutFix.detect(naviKeyCode: settings.hotKeyCode, naviCarbonModifiers: settings.hotKeyModifiers)
        spotlightLoaded = true
        while !Task.isCancelled {
            await perms.refresh()
            loginStatus = LoginItem.status
            if let m = AppDelegate.shared?.services.memory { memoryStatus = m.status }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// A keyboard-key look for shortcut text.
struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
            .foregroundStyle(.primary)
    }
}
