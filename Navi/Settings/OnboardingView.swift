import SwiftUI
import AppKit

enum Onboarding {
    static let key = "hasCompletedOnboarding"
    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// First-launch sheet: Welcome → Sign in → Permissions → Spotlight shortcut → Done.
/// Each step reuses the same rows as the corresponding settings section.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var account = NaviAccount.shared
    @State private var step = 0

    private let steps = ["Welcome", "Sign in", "Permissions", "Shortcut", "Done"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: signIn
                case 2: permissions
                case 3: shortcut
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
            if signedIn, step == 1 { withAnimation { step = 2 } }
        }
    }

    /// Step 1 needs a session (or developer keys) before Continue works.
    private var canContinue: Bool {
        step != 1 || account.isSignedIn || account.hasDeveloperKeys
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HStack(spacing: 18) {
                NaviMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Navi").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("A faster Spotlight that understands what you mean.").font(.title3).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                bullet("bolt.fill", "Navi decides what you want in under a second — apps open instantly.")
                bullet("text.bubble", "Ask anything, or say what to do and Navi does it on your Mac.")
                bullet("brain", "Recall turns your day into a private journal you can ask about.")
                bullet("lock.fill", "One account, one subscription, no API keys. Your screen never leaves this Mac except as short summaries.")
            }
            Spacer()
        }
        .padding(28)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            if account.isSignedIn {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in").font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("\(account.email ?? "Your account") · \(account.planLabel)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Sign in to Navi").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("One account, one subscription, no API keys. 7-day free trial of Pro — no card to start.")
                    .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        account.signIn()
                    } label: {
                        Label(account.isSigningIn ? "Waiting for your browser…" : "Sign in with your browser", systemImage: "safari")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    if account.isSigningIn { ProgressView().controlSize(.small) }
                }
                Text("A page opens in your browser; sign in with email or Google and you'll land back here.")
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
                Text("Grant these now or later from Permissions. Only Accessibility and Screen Recording are needed for tasks; Screen Memory also needs Screen Recording.")
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
                Text("Navi wants ⌘Space. macOS gives that shortcut to Spotlight by default, so Spotlight has to release it — or pick a different combo for Navi.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Navi hotkey") {
                ExplainedRow(title: "Open Navi", explanation: "Click and press a new combo to change it.") { HotKeyRecorderView() }
            }
            Section("Spotlight") { SpotlightFixView() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You're set").font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                Text("Press")
                SettingsKeyCap(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))
                Text("anywhere to open Navi.")
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
