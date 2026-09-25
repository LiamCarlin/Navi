import AppKit
import ApplicationServices

/// Keeps Chrome's remote-debugging chrome out of the user's way. Navi already
/// holds Accessibility, so for as long as it runs it:
///
/// - presses **Allow** on Chrome's "Allow remote debugging?" sheet, which Chrome
///   raises for *every* new CDP connection made through the chrome://inspect toggle
///   (after each sleep, Chrome restart or daemon restart) — but only while a
///   Browser Harness daemon is the one waiting: a `bu*.log` whose last line is
///   `handshake-wait…` with a live pid in `runtime/`. That covers Navi's bundled
///   runtime and dev tools on the repo venv (axprobe, runner replays) alike; a
///   connection some other program opens is never approved on its behalf.
/// - presses **Close** on the "Chrome is being controlled by automated test
///   software" bar, which Chrome drops into tabs whenever a debugger is attached.
///   Never the bar's "Turn off in settings" (that would switch debugging off).
///
/// Chrome is never activated. Each is its own setting (`agentAutoApproveChrome`,
/// `agentHideChromeAutomationBar`).
enum ChromeDebugApproval {
    static let sheetTitle = "Allow remote debugging?"
    static let automationBarText = "controlled by automated test software"
    static let chromeBundleID = "com.google.Chrome"

    private nonisolated(unsafe) static var monitor: Task<Void, Never>?

    /// Starts the monitor once, at launch. A tick is a directory listing plus a few
    /// tiny file reads; the Allow walk only runs while a daemon waits, and the bar
    /// walk (~50 AX elements, ~4 ms warm; web content is skipped) only while Chrome runs.
    static func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let defaults = UserDefaults.standard
                let hideBar = defaults.object(forKey: "agentHideChromeAutomationBar") as? Bool ?? true
                if AXIsProcessTrusted(), !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty {
                    if defaults.object(forKey: "agentAutoApproveChrome") as? Bool ?? true,
                       daemonAwaitingApproval(), pressAllow() {
                        Log.agent.info("chrome: approved a browser-harness remote-debugging connection")
                        // Chrome drops the automation bar in right after an approval: catch it
                        // within ~100 ms. A press while the sheet is still sliding in can be
                        // lost — a daemon still parked after 1 s gets pressed again.
                        for attempt in 1...30 {
                            try? await Task.sleep(for: .milliseconds(100))
                            if daemonAwaitingApproval() {
                                if attempt >= 10 { break }
                                continue
                            }
                            if hideBar, dismissAutomationBar() { break }
                        }
                        continue
                    }
                    if hideBar, dismissAutomationBar() {
                        Log.agent.info("chrome: closed the automated-test-software bar")
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // MARK: Daemon state

    /// Mirrors browser_harness.paths: `$BH_HOME` (or `$XDG_CONFIG_HOME/browser-harness`,
    /// else `~/.config/browser-harness`); daemon logs in `tmp/`, pid files in `runtime/`.
    static func harnessHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = env["BH_HOME"] ?? env["BROWSER_HARNESS_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("browser-harness")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/browser-harness")
    }

    /// Every daemon log in the shared home and the pid file that goes with it:
    /// `tmp/bu-<name>.log` ↔ `runtime/bu-<name>.pid` (one per `BU_NAME`).
    static func daemonFiles(home: URL, logNames: [String]) -> [(log: URL, pid: URL)] {
        logNames.filter { $0.hasPrefix("bu") && $0.hasSuffix(".log") }.sorted().map { name in
            let stem = String(name.dropLast(4))
            return (home.appendingPathComponent("tmp/\(name)"), home.appendingPathComponent("runtime/\(stem).pid"))
        }
    }

    /// The daemon logs `handshake-wait: …` as its last line while Chrome's sheet holds
    /// its connection, and `attached …` / `listening …` once approved.
    static func isAwaitingApproval(logTail: String) -> Bool {
        let last = logTail.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("handshake-wait") } ?? false
    }

    static func daemonAwaitingApproval() -> Bool {
        let home = harnessHome()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("tmp").path)) ?? []
        return daemonFiles(home: home, logNames: names).contains { files in
            guard let log = try? String(contentsOf: files.log, encoding: .utf8), isAwaitingApproval(logTail: log),
                  let data = try? Data(contentsOf: files.pid),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0 else { return false }
            return kill(pid, 0) == 0
        }
    }

    // MARK: Pressing Allow

    /// Finds the sheet on any Chrome window and presses its Allow button via AX
    /// (no activation, no cursor movement). Returns whether a button was pressed.
    static func pressAllow() -> Bool {
        for window in chromeWindows() {
            for sheet in children(window, kAXChildrenAttribute) where string(sheet, kAXRoleAttribute) == kAXSheetRole {
                // The sheet itself is untitled: the question is an AXHeading inside its alert dialog.
                guard mentionsRemoteDebugging(sheet, depth: 0) else { continue }
                if let allow = findButton(titled: "Allow", in: sheet, depth: 0, maxDepth: 8),
                   AXUIElementPerformAction(allow, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    private static func mentionsRemoteDebugging(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = string(element, attribute), text == sheetTitle || text.localizedCaseInsensitiveContains("remote debugging") {
                return true
            }
        }
        return children(element, kAXChildrenAttribute).contains { mentionsRemoteDebugging($0, depth: depth + 1) }
    }

    // MARK: The automation bar

    /// Closes the "Chrome is being controlled by automated test software" bar in every
    /// Chrome window that shows it. The bar is browser UI (above the web area), so the
    /// walk skips page content. Returns whether any bar was closed.
    @discardableResult
    static func dismissAutomationBar() -> Bool {
        var closed = false
        for window in chromeWindows() {
            guard let text = findAutomationText(window, depth: 0) else { continue }
            // The text and its Close button share a container a level or two up;
            // the bar's other button ("Turn off in settings") is never pressed.
            var container = parent(text)
            for _ in 0..<3 {
                guard let c = container else { break }
                if let close = findButton(titled: "Close", in: c, depth: 0, maxDepth: 3) {
                    closed = AXUIElementPerformAction(close, kAXPressAction as CFString) == .success || closed
                    break
                }
                container = parent(c)
            }
        }
        return closed
    }

    private static func findAutomationText(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        let role = string(element, kAXRoleAttribute)
        guard depth < 14, role != "AXWebArea" else { return nil }
        if role == kAXStaticTextRole, let value = string(element, kAXValueAttribute),
           value.localizedCaseInsensitiveContains(automationBarText) {
            return element
        }
        for child in children(element, kAXChildrenAttribute) {
            if let hit = findAutomationText(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    // MARK: AX helpers

    private static func chromeWindows() -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).flatMap {
            children(AXUIElementCreateApplication($0.processIdentifier), kAXWindowsAttribute)
        }
    }

    private static func findButton(titled title: String, in element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXButtonRole,
           string(element, kAXTitleAttribute) == title || string(element, kAXDescriptionAttribute) == title {
            return element
        }
        guard depth < maxDepth else { return nil }
        for child in children(element, kAXChildrenAttribute) {
            if let hit = findButton(titled: title, in: child, depth: depth + 1, maxDepth: maxDepth) { return hit }
        }
        return nil
    }

    private static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
