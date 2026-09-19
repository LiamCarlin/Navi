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
            Image(systemName: "sparkle")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let main = "main"
}

/// Toggles the Dock icon: visible while the main window is open, hidden otherwise.
enum AppActivation {
    @MainActor static func showDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func hideDockIfNoWindows() {
        let visible = NSApp.windows.contains { $0.isVisible && !($0 is NaviPanel) && $0.identifier?.rawValue == WindowID.main }
        if !visible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// The menu shown from the menu-bar sparkle icon.
struct MenuBarMenu: View {
    @EnvironmentObject private var settings: NaviSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Navi  ⌘Space") { AppDelegate.shared?.togglePanel() }
        Button("Navi App & Settings…") {
            openWindow(id: WindowID.main)
            AppActivation.showDock()
        }
        Divider()
        Toggle("Screen Memory", isOn: $settings.memoryCaptureEnabled)
        Divider()
        Button("Quit Navi") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
