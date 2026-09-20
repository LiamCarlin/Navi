import SwiftUI

/// Navi — a Jev-powered Spotlight replacement for macOS.
///
/// Process model: Navi runs as a menu-bar agent (`LSUIElement = true`). The
/// Spotlight-style panel is an `NSPanel` owned by `AppDelegate` and summoned
/// with a global hotkey (⌘Space by default). The "app" the user sees is the
/// `main` window (settings, permissions, memory, usage); closing that window
/// leaves the agent running so ⌘Space keeps working.
@main
struct NaviApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Navi", id: WindowID.main) {
            SettingsRootView()
                .environmentObject(NaviSettings.shared)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { AppActivation.showDock() }
                .onDisappear { AppActivation.hideDockIfNoWindows() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: WindowID.main) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(NaviSettings.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let main = "main"
}

/// The menu-bar icon. It is the one SwiftUI view that is alive for the whole
/// process lifetime, so it doubles as the AppKit → SwiftUI bridge for opening
/// the main window: `AppDelegate.openMainWindow()` posts `.naviOpenMainWindow`
/// and this view calls `openWindow(id:)`.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "sparkle")
            .symbolRenderingMode(.hierarchical)
            .onReceive(NotificationCenter.default.publisher(for: .naviOpenMainWindow)) { _ in
                openWindow(id: WindowID.main)
                AppActivation.showDock()
            }
    }
}

/// Toggles the Dock icon: visible while the main window is open, hidden otherwise.
enum AppActivation {
    /// SwiftUI names the NSWindow for `Window(id: "main")` "main-AppWindow-1".
    @MainActor static func isMainWindow(_ w: NSWindow) -> Bool {
        !(w is NaviPanel) && (w.identifier?.rawValue.hasPrefix(WindowID.main) ?? false)
    }

    @MainActor static var mainWindow: NSWindow? { NSApp.windows.first(where: isMainWindow) }

    @MainActor static func showDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Called after the main window closes. Waits a beat so a window that is
    /// mid-transition isn't miscounted, then drops back to menu-bar-only.
    @MainActor static func hideDockIfNoWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && isMainWindow($0) }
                if !visible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// The menu shown from the menu-bar sparkle icon.
struct MenuBarMenu: View {
    @EnvironmentObject private var settings: NaviSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Navi  ⌘Space") { AppDelegate.shared?.togglePanel() }
        if let vm = AppDelegate.shared?.panelController.viewModel, vm.hasAgentToShow {
            Button(vm.agentRun != nil ? "Show running task…" : "Show last task…") { AppDelegate.shared?.showCurrentTask() }
        }
        Button("Navi App & Settings…") {
            openWindow(id: WindowID.main)
            AppActivation.showDock()
        }
        Divider()
        Menu("Model: \(shortModel(settings.answerModel))") {
            ForEach(NaviSettings.claudeModels, id: \.id) { m in
                Button {
                    settings.answerModel = m.id
                    settings.agentModel = m.id
                } label: {
                    if settings.answerModel == m.id { Label(shortModel(m.id), systemImage: "checkmark") }
                    else { Text(shortModel(m.id)) }
                }
            }
        }
        Divider()
        // Same setting as Settings → Agent; here so it can be flipped between tasks.
        Toggle("Run tasks in background", isOn: $settings.agentRunInBackground)
        Divider()
        Toggle("Screen Memory", isOn: $settings.memoryCaptureEnabled)
        if settings.memoryCaptureEnabled {
            if settings.memoryIsPaused {
                Button("Resume capture") { settings.memoryPausedUntil = nil }
            } else {
                Button("Pause capture for 1 hour") { settings.memoryPausedUntil = Date().addingTimeInterval(3600) }
            }
        }
        Divider()
        Button("Quit Navi") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func shortModel(_ id: String) -> String {
        switch id {
        case "claude-sonnet-5": return "Sonnet 5"
        case "claude-opus-5": return "Opus 5"
        case "claude-haiku-4-5": return "Haiku 4.5"
        default: return id
        }
    }
}
