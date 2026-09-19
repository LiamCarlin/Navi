import SwiftUI
import AppKit
import ServiceManagement

struct GeneralView: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        FormPage(title: "General", subtitle: "Hotkey, startup and appearance.") {
            Section("Hotkey") {
                ExplainedRow(title: "Open Navi", explanation: "Works anywhere, in any app. Default is ⌘Space.") {
                    HotKeyRecorderView()
                }
            }

            Section("Startup") {
                LoginItemRow()
            }

            Section("Appearance") {
                Picker("Window appearance", selection: $settings.appearance) {
                    Text("Match system").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                SpotlightFixView()
            } header: {
                Text("Spotlight shortcut")
            } footer: {
                Text("macOS gives ⌘Space to Spotlight by default. Navi can't receive the shortcut until Spotlight releases it.")
            }
        }
    }
}

// MARK: - Launch at login

struct LoginItemRow: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var status: SMAppService.Status = LoginItem.status
    @State private var error: String?

    var body: some View {
        ExplainedRow(title: "Launch at login", explanation: LoginItem.describe(status)) {
            HStack(spacing: 8) {
                if status == .requiresApproval {
                    Button("Open Login Items…") { LoginItem.openSettings() }.controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { on in
                        do {
                            try LoginItem.set(enabled: on)
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                        status = LoginItem.status
                        settings.launchAtLogin = LoginItem.isEnabled
                    }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .task {
            while !Task.isCancelled {
                status = LoginItem.status
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Spotlight conflict fixer

struct SpotlightFixView: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var status = SpotlightShortcutFix.Status()
    @State private var busy = false
    @State private var message: String?
    @State private var loaded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(level: loaded ? status.level : .off).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(loaded ? status.summary : "Checking Spotlight shortcuts…")
                    .fixedSize(horizontal: false, vertical: true)
                if loaded, status.spotlightSearchEnabled, let code = status.spotlightKeyCode, let flags = status.spotlightCocoaFlags {
                    Text("Spotlight: \(HotKeyManager.describe(keyCode: UInt32(code), modifiers: cocoaToCarbon(flags)))  ·  Navi: \(HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        HStack(spacing: 10) {
            Button("Open Keyboard Shortcuts…") { SpotlightShortcutFix.openKeyboardShortcuts() }
            Button {
                Task { await disable() }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Disable Spotlight's ⌘Space for me") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || (loaded && !status.conflict))
            Spacer()
            Button("Recheck") { Task { await refresh() } }.controlSize(.small).buttonStyle(.borderless)
        }
        .task(id: "\(settings.hotKeyCode)-\(settings.hotKeyModifiers)") { await refresh() }
    }

    private func refresh() async {
        status = await SpotlightShortcutFix.detect(naviKeyCode: settings.hotKeyCode, naviCarbonModifiers: settings.hotKeyModifiers)
        loaded = true
    }

    private func disable() async {
        busy = true
        defer { busy = false }
        do {
            try await SpotlightShortcutFix.disableSpotlightCmdSpace()
            message = "Done. If ⌘Space still opens Spotlight, log out and back in (macOS caches the shortcut table)."
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    private func cocoaToCarbon(_ flags: Int) -> UInt32 {
        var m: UInt32 = 0
        if flags & (1 << 20) != 0 { m |= 256 }
        if flags & (1 << 17) != 0 { m |= 512 }
        if flags & (1 << 19) != 0 { m |= 2048 }
        if flags & (1 << 18) != 0 { m |= 4096 }
        return m
    }
}
