import AppKit
import SwiftUI

/// Owns process-lifetime services: the floating panel, the global hotkey,
/// the query router, and the background memory service.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private(set) var panelController: PanelController!
    private(set) var hotKey: HotKeyManager!
    private(set) var services: NaviServices!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        services = NaviServices.bootstrap()
        panelController = PanelController(services: services)
        hotKey = HotKeyManager()
        hotKey.onActivate = { [weak self] in self?.togglePanel() }
        hotKey.register(settings: NaviSettings.shared)

        services.startBackgroundServices()

        if NaviSettings.shared.isFirstLaunch {
            NaviSettings.shared.isFirstLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.openMainWindow()
            }
        }
        Log.app.info("Navi launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // navi://query?q=... lets other tools (Shortcuts, Raycast, CLI) drive Navi.
        for url in urls {
            guard url.scheme == "navi" else { continue }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            panelController.show(prefill: q, submit: url.host == "run")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stopBackgroundServices()
    }

    // MARK: - Actions

    @objc func togglePanel() {
        panelController.toggle()
    }

    func openMainWindow() {
        AppActivation.showDock()
        // Ask SwiftUI to open (or focus) the main window.
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("openMainWindow:")), to: nil, from: nil)
            NotificationCenter.default.post(name: .naviOpenMainWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let naviOpenMainWindow = Notification.Name("navi.openMainWindow")
    static let naviSettingsChanged = Notification.Name("navi.settingsChanged")
}
