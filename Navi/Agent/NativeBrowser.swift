import AppKit
import Foundation

/// Which browser a web step runs in, and how: through the jev-ultrafast runner
/// (Chrome over CDP — the fastest, richest DOM view, but it needs the Python
/// runtime installed and Chrome's remote debugging switched on) or through the
/// native Jev-first driver on the browser's accessibility tree, which works in
/// **any** browser — Safari, Chrome, Arc, Firefox, Edge, Brave, Orion — with
/// nothing to install beyond the Accessibility permission Navi already has.
///
/// The rule: the browser the user is looking at wins. The runner is used only
/// when that browser is Chromium *and* the runtime is ready; otherwise the
/// page is opened in the user's browser and Jev drives it from the AX tree.
/// A runner that cannot connect falls back the same way, so a fresh install
/// never dead-ends on "runtime not installed".
enum NativeBrowser {
    /// The user's default browser (LaunchServices), as a bundle id.
    static func defaultBrowserBundleID() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    /// The browser a web step should use: the frontmost app if it is a browser,
    /// else the app Navi was invoked over if that is one, else a running
    /// browser (the default one preferred), else the default browser, else Safari.
    @MainActor
    static func choose(frontmost: FrontmostProbe.Info, context: QueryContext) -> String {
        if let b = frontmost.bundleID, AXSnapshotter.isBrowser(b) { return b }
        if let b = context.frontmostApp, AXSnapshotter.isBrowser(b) { return b }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter(AXSnapshotter.isBrowser)
        let preferred = defaultBrowserBundleID()
        if let p = preferred, running.contains(p) { return p }
        if let r = running.first { return r }
        if let p = preferred, NSWorkspace.shared.urlForApplication(withBundleIdentifier: p) != nil { return p }
        return "com.apple.Safari"
    }

    /// Is the jev-ultrafast runner the right tool for this browser right now?
    /// Cheap: a file check plus a set lookup — no doctor script on the hot path.
    static func runnerUsable(for bundleID: String) -> Bool {
        guard UserDefaults.standard.object(forKey: "ultrafastEnabled") as? Bool ?? true else { return false }
        guard AXSnapshotter.chromiumBundles.contains(bundleID) else { return false }
        guard let vendor = UltrafastBridge.vendorDir else { return false }
        return FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent(".venv/bin/python").path)
    }

    /// A runner failure that means "the runner isn't available", not "the task
    /// failed": the native driver should take the step instead.
    static func isRunnerUnavailable(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("runtime not installed") || m.contains("could not start runner") || m.contains("runner exited")
            || m.contains("remote debugging") || m.contains("connect") || m.contains("browser-harness") || m.contains("daemon")
            || m.contains("chrome is not running") || m.contains("no such file")
    }

    /// Opens `url` in the given browser. `activate` brings the browser forward;
    /// background runs leave it where it is (the browser may still take focus
    /// for a new window — that is the browser's choice, not ours).
    @MainActor
    static func open(_ url: String, in bundleID: String, activate: Bool) async -> Bool {
        guard let target = URL(string: url) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            do {
                _ = try await NSWorkspace.shared.open([target], withApplicationAt: app, configuration: config)
                return true
            } catch {
                Log.agent.warning("open \(url, privacy: .public) in \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return NSWorkspace.shared.open(target)
    }

    /// "Safari", "Google Chrome", "Arc" for the timeline.
    static func displayName(_ bundleID: String) -> String { AppSkills.displayName(bundleID: bundleID) }
}
