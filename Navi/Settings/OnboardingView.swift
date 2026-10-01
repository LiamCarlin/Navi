import SwiftUI
import AppKit

enum Onboarding {
    static let key = "hasCompletedOnboarding"
    static var hasCompleted: Bool {
        get { UserDefaults.navi.bool(forKey: key) }
        set { UserDefaults.navi.set(newValue, forKey: key) }
    }
}

/// First-launch sheet: Sign in → Permissions → Spotlight shortcut → Voice → Done.
/// Step one welcomes and says why an account is needed; signing in can wait
/// ("Not now") because apps, files, math and system commands work without one.
/// Each later step reuses the same rows as the corresponding settings section.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var account = NaviAccount.shared
    @StateObject private var voicePerms = PermissionsModel()
    @State private var step = 0

    private let steps = ["Sign in", "Permissions", "Shortcut", "Voice", "Done"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: signIn
                case 1: permissions
                case 2: shortcut
                case 3: voice
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        // The browser round trip lands back here: move on as soon as the session exists.
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn, step == 0 {
                // Let the "You're signed in" confirmation register before moving on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if step == 0 { withAnimation { step = 1 } } }
            }
        }
    }

    /// Step one continues once there is a session (or developer keys); "Not now" skips it.
    private var canContinue: Bool {
        step != 0 || account.isSignedIn || account.hasDeveloperKeys
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            NaviMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Set up Navi").font(.headline)
                Text("Step \(step + 1) of \(steps.count) · \(steps[step])").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 22 : 8, height: 6)
                        .animation(.spring(duration: 0.3), value: step)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Skip setup") { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            Spacer()
            if step > 0 { Button("Back") { withAnimation { step -= 1 } } }
            if step == 0, !canContinue {
                Button("Not now") { withAnimation { step += 1 } }
                    .help("Apps, files, math and system commands work without an account. Sign in later from the menu bar or Account.")
            }
            if step < steps.count - 1 {
                Button("Continue") { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            } else {
                Button("Start using Navi") { finish() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func finish() {
        Onboarding.hasCompleted = true
        isPresented = false
    }

    // MARK: Steps

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Step one: welcome, why there is an account, and the sign-in button.
    private var signIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                NaviMark(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Navi").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Text(account.isSignedIn ? "You're signed in" : "Sign in to Navi")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                }
            }
            if account.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(.green)
                    Text("\(account.email ?? "Your account") · \(account.planLabel)")
                        .font(.title3).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    bullet("text.bubble", "Answers, tasks and voice control run on your Navi account — that's where the thinking happens.")
                    bullet("creditcard", "One subscription covers everything: no API keys, nothing to set up. 7-day free trial of Pro, no card to start.")
                    bullet("bolt.fill", "Apps, files, math and Mac controls work right away, with or without an account.")
                    bullet("waveform", "Talk to it: press \(HotKeyManager.describe(keyCode: settings.voiceHotKeyCode, modifiers: settings.voiceHotKeyModifiers)) and say what you want — in any app, in any browser.")
                    bullet("clock.arrow.circlepath", "Recall turns your day into a private journal, kept on this Mac, that you can ask about.")
                }
                .font(.callout)
                SignInButton(account: account)
                Text("A page opens in your browser. Sign in with your email, Google or Apple and you'll land back here.")
                    .font(.caption).foregroundStyle(.tertiary)
                if let err = account.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if account.hasDeveloperKeys {
                    Label("Developer mode: your own keys are in use, so you can continue without signing in.", systemImage: "hammer")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(28)
    }

    private var permissions: some View {
        Form {
            Section {
                Text("Grant these now or later under Permissions. Tasks need Accessibility and Screen Recording; Recall needs Screen Recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section { PermissionsList() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var shortcut: some View {
        Form {
            Section {
                Text("Navi works best on ⌘Space. macOS gives that shortcut to Spotlight, so Spotlight has to let it go — or pick a different shortcut for Navi.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Navi hotkey") {
                ExplainedRow(title: "Open Navi", explanation: "Click, then press a new shortcut to change it.") { HotKeyRecorderView() }
            }
            Section("Spotlight") { SpotlightFixView() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var voice: some View {
        Form {
            Section {
                Text("Voice control is the fastest way to use Navi: hold nothing, press nothing — say “open Safari, go to YouTube and play lo-fi beats” and watch it happen while you're still talking.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                PermissionRow(title: "Microphone",
                              explanation: "Recognized on this Mac by Apple's on-device model. Audio never leaves your Mac.",
                              state: voicePerms.microphone,
                              request: { Task { _ = await Permissions.requestMicrophone(); await voicePerms.refresh() } },
                              open: { Permissions.openSettings(.microphone) })
                    .task { await voicePerms.poll() }
                ExplainedRow(title: "Voice shortcut", explanation: "Press anywhere to start or stop listening.") {
                    HotKeyRecorderView(kind: .voice)
                }
            }
            Section {
                Picker("Ask me", selection: $settings.agentApprovalMode) {
                    ForEach(ApprovalMode.allCases) { Text(AgentSettingsView.label(for: $0)).tag($0) }
                }
                Text(AgentSettingsView.explanation(for: settings.agentApprovalMode))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("When Navi does things for you")
            } footer: {
                Text("Applies to typed and spoken tasks. You can change it later under Tasks.")
            }
            Section {
                Button {
                    finishSoftly()
                    AppDelegate.shared?.toggleVoice()
                } label: { Label("Try voice control now", systemImage: "waveform") }
                .disabled(voicePerms.microphone == .denied)
            } footer: {
                Text("Say “stop” to cancel, “undo” to undo the last step, and “stop listening” when you’re done.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Marks onboarding done without closing the window (the island appears over it).
    private func finishSoftly() { Onboarding.hasCompleted = true }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You're set").font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                Text("Press")
                SettingsKeyCap(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
                Text("to open Navi,")
                SettingsKeyCap(HotKeyManager.describe(keyCode: settings.voiceHotKeyCode, modifiers: settings.voiceHotKeyModifiers))
                Text("to talk to it.")
            }
            .font(.title3).foregroundStyle(.secondary)
            Button {
                AppDelegate.shared?.togglePanel()
            } label: {
                Label("Try it now", systemImage: "sparkles").padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            Text("This window lives in the menu bar (✦). Close it and Navi keeps running.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(28)
    }
}
