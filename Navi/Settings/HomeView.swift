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
    @ObservedObject private var account = NaviAccount.shared

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                PlanCard()
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
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 22) {
            NaviMark(size: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text("Navi").font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("Press")
                    SettingsKeyCap(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
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
        StatusCard(title: "Account", detail: accountDetail, level: accountLevel,
                   fixTitle: account.isSignedIn ? "Open" : "Sign in") {
            if account.isSignedIn { nav.go(.account) } else { account.signIn() }
        }
        StatusCard(title: "Accessibility", detail: perms.accessibility == .granted ? "Granted. The agent can click and type." : "Needed for the agent to click and type.",
                   level: perms.accessibility.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Screen Recording", detail: perms.screenRecording == .granted ? "Granted. Agent and Screen Memory can see the screen." : "Needed for the agent and Screen Memory.",
                   level: perms.screenRecording.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Automation", detail: automationDetail, level: perms.automation.level, fixTitle: "Grant") { nav.go(.permissions) }
        StatusCard(title: "Spotlight shortcut", detail: spotlightLoaded ? spotlight.summary : "Checking…",
                   level: spotlightLoaded ? spotlight.level : .off, fixTitle: "Fix") { nav.go(.general) }
        StatusCard(title: "Recall", detail: memoryDetail, level: memoryLevel,
                   fixTitle: !account.entitlements.recall ? "Unlock" : (settings.memoryCaptureEnabled ? "Open" : "Turn on")) { nav.go(.memory) }
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

    private var accountDetail: String {
        if account.isSignedIn { return "Signed in as \(account.email ?? "you") · \(account.tier.displayName)." }
        if account.hasDeveloperKeys { return "Developer mode — your own keys are in use." }
        return "Sign in for answers, tasks and voice control. 7-day free trial of Pro."
    }

    private var accountLevel: StatusLevel {
        account.isSignedIn || account.hasDeveloperKeys ? .ok : .bad
    }

    private var memoryDetail: String {
        if !account.entitlements.recall { return "Not in your plan. Add Recall to ask \"what was I doing yesterday?\"" }
        if !settings.memoryCaptureEnabled { return "Off. Turn it on to ask \"what was I doing yesterday?\"" }
        if settings.memoryIsPaused, let u = settings.memoryPausedUntil { return "Paused until \(u.formatted(date: .omitted, time: .shortened))." }
        if memoryStatus.isRunning { return "Running · \(memoryStatus.framesToday) frames today · \(memoryStatus.vaultNoteCount) notes." }
        return "Enabled but not running."
    }

    private var memoryLevel: StatusLevel {
        if !account.entitlements.recall { return .off }
        if !settings.memoryCaptureEnabled { return .off }
        if settings.memoryIsPaused { return .warn }
        return memoryStatus.isRunning ? .ok : .warn
    }

    private var readyLine: String {
        var issues = 0
        if !(account.isSignedIn || account.hasDeveloperKeys) { issues += 1 }
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
                tip("maps", "opens Apple Maps — Navi decides in under a second")
                tip("12% of 340", "instant math, currency and time zones")
                tip("why is the sky blue", "streams an answer")
                tip("open chrome and search for jev", "Navi does it for you")
                tip("what was I reading yesterday", "asks Recall")
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

    private func poll() async {
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
struct SettingsKeyCap: View {
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


/// The plan card on Home: tier, trial, today's usage, one "Manage" button.
/// Signed out: the sign-in call to action. Nothing here names a vendor.
struct PlanCard: View {
    @ObservedObject private var account = NaviAccount.shared
    @ObservedObject private var nav = SettingsNavigator.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: account.isSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.plus")
                .font(.system(size: 28)).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                if account.isSignedIn {
                    HStack(spacing: 8) {
                        Text("\(account.tier.displayName) plan").font(.title3.weight(.semibold))
                        if let days = account.trialDaysLeft {
                            Text("Trial · \(days) day\(days == 1 ? "" : "s") left")
                                .font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(usageLine).font(.callout).foregroundStyle(.secondary)
                } else if account.hasDeveloperKeys {
                    Text("Developer mode").font(.title3.weight(.semibold))
                    Text("Your own keys are in use. Sign in to use a Navi plan instead.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Sign in to Navi").font(.title3.weight(.semibold))
                    Text("One account, one subscription, no API keys. 7-day free trial of Pro.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isSignedIn {
                Button("Manage") { nav.go(.account) }.buttonStyle(.bordered)
            } else {
                Button {
                    account.signIn()
                } label: {
                    Label("Sign in with your browser", systemImage: "safari").padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var usageLine: String {
        var parts = [account.answersLine, account.tasksLine]
        if account.entitlements.recall { parts.append("Recall on") }
        return parts.joined(separator: " · ")
    }
}
