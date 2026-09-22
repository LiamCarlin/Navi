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
    /// Voice control: the notch island + its session. Created lazily on first use.
    private(set) var voice: VoiceIslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        Keychain.preload()   // background; UI never blocks on the Keychain ACL prompt

        services = NaviServices.bootstrap()
        panelController = PanelController(services: services)
        panelController.viewModel.onVoiceRequested = { [weak self] in self?.toggleVoice() }
        hotKey = HotKeyManager()
        hotKey.onActivate = { [weak self] in self?.togglePanel() }
        hotKey.register(settings: NaviSettings.shared)

        services.startBackgroundServices()
        UltrafastBridge.prewarm()
        Updater.shared.start()   // appcast check 30 s after launch, then daily (App/Updater.swift)
        NotificationCenter.default.addObserver(forName: .naviShowCurrentTask, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCurrentTask() }
        }

        // Drop the Dock icon again once the main window closes.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let w = note.object as? NSWindow, AppActivation.isMainWindow(w) { AppActivation.hideDockIfNoWindows() }
            }
        }

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
            #if DEBUG
            if DebugSnapshot.handle(url) { continue }   // navi://debug-snapshot (Settings/DebugSnapshot.swift)
            if DebugJevProbe.handle(url, jev: services.jev) { continue }   // navi://debug-jev-probe
            if DebugPlanProbe.handle(url, claude: services.claude) { continue }   // navi://debug-plan?q=…
            #endif
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if url.host == "voice" {
                // navi://voice toggles voice control; navi://voice?file=/path.aiff feeds a recording (debug).
                if let f = comps?.queryItems?.first(where: { $0.name == "file" })?.value, !f.isEmpty {
                    voiceController.start(audioFile: URL(fileURLWithPath: f))
                } else {
                    toggleVoice()
                }
                continue
            }
            let q = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            panelController.show(prefill: q, submit: url.host == "run")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        voice?.stop()
        services.stopBackgroundServices()
    }

    // MARK: - Actions

    @objc func togglePanel() {
        panelController.toggle()
    }

    var voiceController: VoiceIslandController {
        if let voice { return voice }
        let v = VoiceIslandController(session: VoiceSession(services: services))
        voice = v
        return v
    }

    /// Start (or stop) live voice control: the island drops out of the notch
    /// and Navi acts on each instruction as it is spoken.
    func toggleVoice() {
        if panelController.isVisible { panelController.hide() }
        voiceController.toggle()
    }

    /// Brings the panel up on the running (or just-finished) agent task.
    func showCurrentTask() {
        panelController.viewModel.showAgent()
        if !panelController.isVisible { panelController.show() }
    }

    /// Opens (or focuses) the main SwiftUI window, optionally at a section.
    func openMainWindow(section: SettingsSection? = nil) {
        if let section { SettingsNavigator.shared.go(section) }
        AppActivation.showDock()
        if let existing = AppActivation.mainWindow {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // `MenuBarLabel` (always alive) receives this and calls openWindow(id:).
            NotificationCenter.default.post(name: .naviOpenMainWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let naviOpenMainWindow = Notification.Name("navi.openMainWindow")
    static let naviSettingsChanged = Notification.Name("navi.settingsChanged")
    /// Posted by the agent overlay: bring the panel up on the current task.
    static let naviShowCurrentTask = Notification.Name("navi.showCurrentTask")
}
