import SwiftUI
import AppKit

struct AboutView: View {
    @EnvironmentObject private var settings: NaviSettings
    @ObservedObject private var updater = Updater.shared
    @State private var developerCaption: String?

    static let privacyURL = "https://navi.app/privacy"
    static let termsURL = "https://navi.app/terms"
    static let supportEmail = "support@navi.app"

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        FormPage(title: "About", subtitle: "Updates, support and the fine print.") {
            Section {
                HStack(spacing: 16) {
                    NaviMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Navi").font(.title2.weight(.semibold))
                        Text("Press \(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)) and say what you want.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Version") {
                    Text(version)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        .onTapGesture { versionTapped() }
                        .help("Option-click to toggle developer mode")
                }
                HStack(spacing: 12) {
                    Button("Check for Updates…") { updater.checkForUpdates(userInitiated: true) }
                        .disabled(updater.state == .checking)
                    if updater.state == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let developerCaption {
                    Label(developerCaption, systemImage: "hammer")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Links") {
                LinkPill(title: "Privacy policy", url: Self.privacyURL)
                LinkPill(title: "Terms of use", url: Self.termsURL)
                LinkPill(title: "Contact support", url: "mailto:\(Self.supportEmail)")
            }

            Section {
                HStack {
                    Button("Quit Navi", role: .destructive) { NSApp.terminate(nil) }
                    Text("Stops the shortcut, voice control and Recall until you open Navi again.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    /// ⌥-click on the version toggles the hidden Developer section.
    private func versionTapped() {
        guard NSEvent.modifierFlags.contains(.option) else { return }
        DeveloperMode.isEnabled.toggle()
        developerCaption = DeveloperMode.isEnabled ? "Developer mode on" : "Developer mode off"
        // The sidebar lists sections from `SettingsSection.allCases`; nudge it to re-read.
        SettingsNavigator.shared.objectWillChange.send()
    }
}

/// The Navi mark: a sparkle on a soft gradient tile.
struct NaviMark: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.accentColor.opacity(0.3), radius: size * 0.15, y: size * 0.06)
    }
}
