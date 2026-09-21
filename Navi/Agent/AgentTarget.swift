import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The app a native step drives, pinned for the length of the step.
///
/// In the foreground mode the agent works on whatever is frontmost and
/// activates it before every synthetic event. In **background mode** the user
/// keeps working in other apps while Navi runs, so "frontmost" is meaningless:
/// the accessibility walk, the input events and the screenshots all have to
/// address one specific process — this one.
struct AgentTarget: Sendable, Equatable {
    var pid: pid_t
    var bundleID: String?
    var appName: String?

    static let selfPID = ProcessInfo.processInfo.processIdentifier

    // MARK: Resolution

    /// The running app for `bundleID` (after `open_app`), if any.
    @MainActor
    static func running(bundleID: String) -> AgentTarget? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              app.processIdentifier != selfPID else { return nil }
        return AgentTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, appName: app.localizedName)
    }

    /// After `open_app`: the app by bundle id, or — when LaunchServices only
    /// gave us back a name — by its localized name.
    @MainActor
    static func running(bundleIDOrName id: String) -> AgentTarget? {
        if let t = running(bundleID: id) { return t }
        let wanted = id.lowercased().replacingOccurrences(of: ".app", with: "")
        guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").lowercased() == wanted }),
              app.processIdentifier != selfPID else { return nil }
        return AgentTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, appName: app.localizedName)
    }

    /// Whatever is frontmost right now, unless that is Navi itself.
    @MainActor
    static func frontmost() -> AgentTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != selfPID else { return nil }
        return AgentTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, appName: app.localizedName)
    }

    /// The app to drive when the plan names none: the app that was in front
    /// when the user opened Navi (`QueryContext`), else the current frontmost.
    @MainActor
    static func `default`(context: QueryContext) -> AgentTarget? {
        if let b = context.frontmostApp, let t = running(bundleID: b) { return t }
        return frontmost()
    }

    /// Waits (≤ `maxMs`) for the app to have a window the agent can address.
    /// A freshly launched app can take a second to put one up.
    func waitForWindow(maxMs: Int = 4000) async {
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(maxMs) {
            if await AXQueue.run({ AgentTarget.axWindow(pid: self.pid) != nil }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    var isRunning: Bool { NSRunningApplication(processIdentifier: pid)?.isTerminated == false }

    /// Brings the app and the window the agent worked in to the front. The one
    /// activation background mode allows — after the run, when the window *is*
    /// the result ("make a note", "create the event") and would otherwise stay
    /// hidden behind whatever the user was doing. Unhides the app if the user
    /// had it hidden; a minimised window is restored through AX.
    func reveal() async {
        guard isRunning else { return }
        await AXQueue.run {
            guard let w = Self.axWindow(pid: self.pid) else { return }
            if (AXSnapshotter.attr(w, kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            if app.isHidden { app.unhide() }
            app.activate()
        }
        Log.agent.info("Revealed \(appName ?? bundleID ?? "the app", privacy: .public) after the run")
    }

    // MARK: Windows

    /// Focused → main → first window of the app, via AX. Runs on `AXQueue`.
    static func axWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let w = AXSnapshotter.attr(app, kAXFocusedWindowAttribute) as! AXUIElement? { return w }
        if let w = AXSnapshotter.attr(app, kAXMainWindowAttribute) as! AXUIElement? { return w }
        return AXSnapshotter.elements(AXSnapshotter.attr(app, kAXWindowsAttribute))?.first
    }

    /// One on-screen window as the window server lists it.
    struct WindowInfo: Sendable, Equatable {
        var id: CGWindowID
        var pid: pid_t
        var title: String
        /// Global points, top-left origin (CGWindowList space == CGEvent space).
        var bounds: CGRect
        var layer: Int
        var isOnScreen: Bool
    }

    /// The app's normal-layer windows, front to back.
    func windows() -> [WindowInfo] {
        Self.windowList(pid: pid)
    }

    static func windowList(pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { bounds = r }
            return WindowInfo(id: id, pid: owner, title: w[kCGWindowName as String] as? String ?? "",
                              bounds: bounds, layer: layer, isOnScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    /// The window-server window that matches the AX window the snapshot was
    /// taken from, for routing events and window capture. Pure: testable.
    ///
    /// AX exposes no window number, so match on geometry (the AX frame and the
    /// CG bounds agree to the point) and, failing that, on title; otherwise the
    /// frontmost normal-layer window of the app.
    static func matchWindow(_ candidates: [WindowInfo], frame: CGRect?, title: String?) -> WindowInfo? {
        let normal = candidates.filter { $0.layer == 0 && $0.bounds.width >= 1 && $0.bounds.height >= 1 }
        guard !normal.isEmpty else { return nil }
        if let frame, !frame.isEmpty {
            func distance(_ w: WindowInfo) -> CGFloat {
                abs(w.bounds.minX - frame.minX) + abs(w.bounds.minY - frame.minY)
                    + abs(w.bounds.width - frame.width) + abs(w.bounds.height - frame.height)
            }
            if let best = normal.min(by: { distance($0) < distance($1) }), distance(best) <= 4 { return best }
        }
        if let title, !title.isEmpty, let byTitle = normal.first(where: { $0.title == title }) { return byTitle }
        return normal.first(where: \.isOnScreen) ?? normal.first
    }

    /// The window-server window behind `snapshot` (its window frame / title).
    func window(for snapshot: AXSnapshot) -> WindowInfo? {
        Self.matchWindow(windows(), frame: snapshot.windowFrame, title: snapshot.windowTitle)
    }

    /// The app's current focused/main window as the window server knows it
    /// (for screenshots and event routing when there is no snapshot to hand).
    func currentWindow() async -> WindowInfo? {
        let (frame, title): (CGRect?, String?) = await AXQueue.run {
            guard let w = Self.axWindow(pid: self.pid) else { return (nil, nil) }
            return (AXSnapshotter.frame(of: w), AXSnapshotter.attr(w, kAXTitleAttribute) as? String)
        }
        return Self.matchWindow(windows(), frame: frame, title: title)
    }

    // MARK: Context

    /// What `FrontmostProbe.current` reports for the frontmost app, but for
    /// this app: name, focused-window title and (browsers) the active tab URL.
    func info(includeURL: Bool) async -> FrontmostProbe.Info {
        var info = FrontmostProbe.Info(bundleID: bundleID, appName: appName)
        info.windowTitle = await AXQueue.run {
            guard let w = Self.axWindow(pid: self.pid) else { return nil }
            return AXSnapshotter.attr(w, kAXTitleAttribute) as? String
        }
        if includeURL, let b = bundleID, AXSnapshotter.isBrowser(b) {
            info.url = FrontmostProbe.browserURL(bundleID: b)
        }
        return info
    }

    /// True when the focused element *of this app* is a password field.
    /// (`InputController.focusedElementIsSecureField` asks the system-wide
    /// focus, which in background mode belongs to whatever the user is typing in.)
    func focusedElementIsSecureField() async -> Bool {
        await AXQueue.run {
            let app = AXUIElementCreateApplication(self.pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let f = AXSnapshotter.attr(app, kAXFocusedUIElementAttribute) as! AXUIElement? else { return false }
            if (AXSnapshotter.attr(f, kAXRoleAttribute) as? String) == "AXSecureTextField" { return true }
            return (AXSnapshotter.attr(f, kAXSubroleAttribute) as? String) == "AXSecureTextField"
        }
    }
}
