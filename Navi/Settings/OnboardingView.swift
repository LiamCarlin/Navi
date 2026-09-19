import SwiftUI
import AppKit

enum Onboarding {
    static let key = "hasCompletedOnboarding"
    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// First-launch sheet: Welcome → API keys → Permissions → Spotlight shortcut → Done.
/// Each step reuses the same rows as the corresponding settings section.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: NaviSettings
    @State private var step = 0

    private let steps = ["Welcome", "Keys", "Permissions", "Shortcut", "Done"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: keys
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
                bullet("bolt.fill", "Jev (TypeSafe System One) decides what you want in about 100 ms — apps open instantly.")
                bullet("text.bubble", "Claude answers questions and runs multi-step tasks on your Mac.")
                bullet("brain", "Screen Memory turns your day into an Obsidian vault you can ask about.")
                bullet("lock.fill", "Keys live in your Keychain. Screen data never leaves this Mac except to the models you choose.")
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

    private var keys: some View {
        Form {
            Section {
                Text("Navi needs a Jev key (TypeSafe direct, or Vercel AI Gateway — either works) and a Claude key. See AI Providers later for the full list of deals.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                APIKeyRow(key: .typesafe, title: "Jev (TypeSafe)", subtitle: "console.typesafe.ai/keys · early access",
                          placeholder: "ts-…", optional: true, test: ProviderTests.jev)
                APIKeyRow(key: .vercelGateway, title: "Jev via Vercel AI Gateway", subtitle: "vercel.com/ai-gateway → API Keys · no waitlist",
                          placeholder: "vck_…", optional: true, test: ProviderTests.jevVercel)
                APIKeyRow(key: .anthropic, title: "Anthropic (Claude)", subtitle: "platform.claude.com",
                          placeholder: "sk-ant-…", test: ProviderTests.claude)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
