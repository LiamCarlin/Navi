import AppKit
import ApplicationServices

/// Chrome asks "Allow remote debugging?" for *every* new CDP connection made
/// through the chrome://inspect toggle — so after each sleep, Chrome restart or
/// daemon restart the Browser Harness daemon parks on that sheet until the user
/// clicks Allow. Navi already holds Accessibility, so it presses Allow itself.
///
/// Only while Navi's own daemon is the one waiting: its log's last line is
/// `handshake-wait…` and its pid file names a live process. A connection some
/// other program opens is never approved on its behalf. Chrome is not activated.
enum ChromeDebugApproval {
    static let sheetTitle = "Allow remote debugging?"

    /// Watches for the sheet for up to `seconds` (or until cancelled) and presses
    /// Allow whenever our daemon is parked on it. Cheap: one tiny file read per
    /// tick; the AX walk only runs while the daemon is actually waiting.
    @discardableResult
    static func watch(for seconds: TimeInterval) -> Task<Void, Never>? {
        guard UserDefaults.standard.object(forKey: "agentAutoApproveChrome") as? Bool ?? true,
              AXIsProcessTrusted() else { return nil }
        return Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(seconds)
            while !Task.isCancelled, Date() < deadline {
                if daemonAwaitingApproval(), pressAllow() {
                    Log.agent.info("chrome: approved Navi's remote-debugging connection")
                    // The daemon attaches within a few hundred ms; don't press twice.
                    try? await Task.sleep(for: .seconds(2))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: Daemon state

    /// Mirrors browser_harness.paths / _ipc: `$BH_HOME` (or `$XDG_CONFIG_HOME/browser-harness`,
    /// else `~/.config/browser-harness`), log in `tmp/`, pid in `runtime/`.
    static func harnessFiles(env: [String: String] = ProcessInfo.processInfo.environment) -> (log: URL, pid: URL) {
        let home: URL
        if let raw = env["BH_HOME"] ?? env["BROWSER_HARNESS_HOME"], !raw.isEmpty {
            home = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            home = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("browser-harness")
        } else {
            home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/browser-harness")
        }
        let name = env["BU_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let tmpDir = env["BH_TMP_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let runtimeDir = (env["BH_RUNTIME_DIR"] ?? env["BH_TMP_DIR"]).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let tmpStem = tmpDir != nil && env["BH_TMP_DIR_SHARED"] != "1" ? "bu" : "bu-\(name)"
        let runtimeStem = runtimeDir != nil && env["BH_RUNTIME_DIR_SHARED"] != "1" ? "bu" : "bu-\(name)"
        return ((tmpDir ?? home.appendingPathComponent("tmp")).appendingPathComponent("\(tmpStem).log"),
                (runtimeDir ?? home.appendingPathComponent("runtime")).appendingPathComponent("\(runtimeStem).pid"))
    }

    /// The daemon logs `handshake-wait: …` as its last line while Chrome's sheet holds
    /// its connection, and `attached …` / `listening …` once approved.
    static func isAwaitingApproval(logTail: String) -> Bool {
        let last = logTail.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("handshake-wait") } ?? false
    }

    static func daemonAwaitingApproval() -> Bool {
        let files = harnessFiles()
        guard let log = try? String(contentsOf: files.log, encoding: .utf8), isAwaitingApproval(logTail: log),
              let data = try? Data(contentsOf: files.pid),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: Pressing Allow

    /// Finds the sheet on any Chrome window and presses its Allow button via AX
    /// (no activation, no cursor movement). Returns whether a button was pressed.
    static func pressAllow() -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome") {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            for window in children(axApp, kAXWindowsAttribute) {
                for sheet in children(window, kAXChildrenAttribute) where string(sheet, kAXRoleAttribute) == kAXSheetRole {
                    // The sheet itself is untitled: the question is an AXHeading inside its alert dialog.
                    guard mentionsRemoteDebugging(sheet, depth: 0) else { continue }
                    if let allow = findAllowButton(sheet, depth: 0),
                       AXUIElementPerformAction(allow, kAXPressAction as CFString) == .success {
                        return true
                    }
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

    private static func findAllowButton(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if string(element, kAXRoleAttribute) == kAXButtonRole,
           string(element, kAXTitleAttribute) == "Allow" || string(element, kAXDescriptionAttribute) == "Allow" {
            return element
        }
        for child in children(element, kAXChildrenAttribute) {
            if let hit = findAllowButton(child, depth: depth + 1) { return hit }
        }
        return nil
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
