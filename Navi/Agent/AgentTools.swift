import AppKit
import Foundation

// MARK: - Screenshot ↔ screen coordinate mapping

/// Maps coordinates in the (downscaled) screenshot Claude saw back to global
/// screen points for CGEvent, and vice versa. One instance per screenshot.
struct ScreenMap: Sendable, Equatable {
    /// Display bounds in global points (CGDisplayBounds).
    var bounds: CGRect
    /// Points → pixels (2.0 on Retina).
    var scaleFactor: CGFloat
    /// Factor applied when downscaling the full-res capture (≤ 1).
    var downscale: CGFloat
    /// Size of the image Claude received, in pixels.
    var imageSize: CGSize

    /// Screenshot pixel → screen point. Clamped to the display bounds.
    func point(fromScreenshot x: Double, _ y: Double) -> CGPoint {
        let px = bounds.origin.x + (CGFloat(x) / downscale) / scaleFactor
        let py = bounds.origin.y + (CGFloat(y) / downscale) / scaleFactor
        return CGPoint(x: min(max(px, bounds.minX), bounds.maxX - 1),
                       y: min(max(py, bounds.minY), bounds.maxY - 1))
    }

    /// Screen point → screenshot pixel (for `cursor_position`).
    func screenshotPoint(fromScreen p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.origin.x) * scaleFactor * downscale,
                y: (p.y - bounds.origin.y) * scaleFactor * downscale)
    }

    /// Screenshot pixel rect → full-resolution capture pixel rect (for `zoom`).
    func fullResRect(fromScreenshot r: CGRect) -> CGRect {
        CGRect(x: r.origin.x / downscale, y: r.origin.y / downscale,
               width: r.width / downscale, height: r.height / downscale)
    }
}

// MARK: - Tool calls / results

/// One `tool_use` block from Claude, normalised.
struct AgentToolCall: @unchecked Sendable {
    let id: String
    let name: String
    /// True for members of the `computer` toolset (`toolset_name == "computer"`).
    let isComputer: Bool
    let input: [String: Any]

    init?(block: [String: Any]) {
        guard block["type"] as? String == "tool_use",
              let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.isComputer = (block["toolset_name"] as? String) == "computer"
        self.input = block["input"] as? [String: Any] ?? [:]
    }

    var coordinate: (Double, Double)? { Self.pair(input["coordinate"]) }
    var startCoordinate: (Double, Double)? { Self.pair(input["start_coordinate"]) }
    var text: String? { input["text"] as? String }

    static func pair(_ v: Any?) -> (Double, Double)? {
        guard let a = v as? [Any], a.count >= 2,
              let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue else { return nil }
        return (x, y)
    }

    /// Actions that only observe and never change anything.
    var isReadOnly: Bool {
        if isComputer {
            return ["screenshot", "zoom", "cursor_position", "mouse_move", "wait"].contains(name)
        }
        return ["read_clipboard", "report_progress"].contains(name)
    }
}

/// Builders for `tool_result` blocks. Computer members MUST carry
/// `toolset_name: "computer"`; custom tools MUST NOT.
enum AgentToolResult {
    static let notExecuted = "Not executed: an earlier computer action in this turn failed."
    static let declined = "User declined this action"

    static func computer(id: String, text: String = "OK", isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = [
            "type": "tool_result", "tool_use_id": id, "toolset_name": "computer",
            "content": [["type": "text", "text": text]],
        ]
        if isError { r["is_error"] = true }
        return r
    }

    static func computerImage(id: String, pngBase64: String) -> [String: Any] {
        [
            "type": "tool_result", "tool_use_id": id, "toolset_name": "computer",
            "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": pngBase64]]],
        ]
    }

    static func custom(id: String, text: String, isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = [
            "type": "tool_result", "tool_use_id": id,
            "content": [["type": "text", "text": text]],
        ]
        if isError { r["is_error"] = true }
        return r
    }

    /// Picks the right shape for the call.
    static func error(for call: AgentToolCall, _ text: String) -> [String: Any] {
        call.isComputer ? computer(id: call.id, text: text, isError: true) : custom(id: call.id, text: text, isError: true)
    }

    static func ok(for call: AgentToolCall, _ text: String = "OK") -> [String: Any] {
        call.isComputer ? computer(id: call.id, text: text) : custom(id: call.id, text: text)
    }

    /// Replaces image content in all but the last `keep` image tool_results with
    /// a text placeholder so request bodies stay small over long runs.
    static func pruneImages(in messages: inout [[String: Any]], keep: Int) {
        var imageLocations: [(Int, Int)] = []   // (message index, block index)
        for (mi, m) in messages.enumerated() where m["role"] as? String == "user" {
            guard let blocks = m["content"] as? [[String: Any]] else { continue }
            for (bi, b) in blocks.enumerated() where b["type"] as? String == "tool_result" {
                if let c = b["content"] as? [[String: Any]], c.contains(where: { $0["type"] as? String == "image" }) {
                    imageLocations.append((mi, bi))
                }
            }
        }
        guard imageLocations.count > keep else { return }
        for (mi, bi) in imageLocations.dropLast(keep) {
            var m = messages[mi]
            var blocks = m["content"] as! [[String: Any]]
            blocks[bi]["content"] = [["type": "text", "text": "(earlier screenshot omitted to save context)"]]
            m["content"] = blocks
            messages[mi] = m
        }
    }
}

// MARK: - Descriptions

enum AgentActionDescriber {
    private static func fmt(_ p: (Double, Double)?) -> String {
        guard let p else { return "current position" }
        return "(\(Int(p.0.rounded())), \(Int(p.1.rounded())))"
    }

    private static func short(_ s: String, _ n: Int = 48) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "⏎")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// Friendly text for `.step` events ("Click at (512, 384)", "Press ⌘S").
    static func human(_ c: AgentToolCall) -> String {
        if c.isComputer {
            let mod = c.text.map { " (\($0)-click)" } ?? ""
            switch c.name {
            case "screenshot": return "Take screenshot"
            case "zoom": return "Zoom into region"
            case "left_click": return "Click at \(fmt(c.coordinate))\(mod)"
            case "right_click": return "Right-click at \(fmt(c.coordinate))\(mod)"
            case "middle_click": return "Middle-click at \(fmt(c.coordinate))"
            case "double_click": return "Double-click at \(fmt(c.coordinate))\(mod)"
            case "triple_click": return "Triple-click at \(fmt(c.coordinate))\(mod)"
            case "left_click_drag": return "Drag from \(fmt(c.startCoordinate)) to \(fmt(c.coordinate))"
            case "mouse_move": return "Move mouse to \(fmt(c.coordinate))"
            case "left_mouse_down": return "Mouse down"
            case "left_mouse_up": return "Mouse up"
            case "cursor_position": return "Read cursor position"
            case "scroll":
                let dir = c.input["scroll_direction"] as? String ?? "down"
                let amt = (c.input["scroll_amount"] as? NSNumber)?.intValue ?? 3
                return "Scroll \(dir) \(amt) at \(fmt(c.coordinate))"
            case "type": return "Type '\(short(c.text ?? ""))'"
            case "key":
                let label = (try? KeyCombo.parse(c.text ?? "").displayLabel) ?? (c.text ?? "?")
                let rep = (c.input["repeat"] as? NSNumber)?.intValue ?? 1
                return rep > 1 ? "Press \(label) ×\(rep)" : "Press \(label)"
            case "hold_key":
                let d = (c.input["duration"] as? NSNumber)?.doubleValue ?? 1
                return "Hold \(c.text ?? "?") for \(d)s"
            case "wait":
                let d = (c.input["duration"] as? NSNumber)?.doubleValue ?? 1
                return "Wait \(d)s"
            default: return "Computer action: \(c.name)"
            }
        }
        switch c.name {
        case "open_app": return "Open \(c.input["name"] as? String ?? "app")"
        case "open_url": return "Open URL \(short(c.input["url"] as? String ?? "", 60))"
        case "run_applescript": return "Run AppleScript"
        case "read_clipboard": return "Read clipboard"
        case "write_clipboard": return "Copy to clipboard: '\(short(c.input["text"] as? String ?? ""))'"
        case "report_progress": return short(c.input["message"] as? String ?? "Progress", 80)
        default: return "Tool: \(c.name)"
        }
    }

    /// Compact technical line for Jev's [PROPOSED_ACTIONS] ("left_click at (512,384)").
    static func technical(_ c: AgentToolCall) -> String {
        func xy(_ p: (Double, Double)?) -> String { p.map { "(\(Int($0.0)),\(Int($0.1)))" } ?? "(cursor)" }
        if c.isComputer {
            switch c.name {
            case "screenshot", "cursor_position", "left_mouse_down", "left_mouse_up": return c.name
            case "zoom": return "zoom region=\(c.input["region"] ?? "?")"
            case "left_click", "right_click", "middle_click", "double_click", "triple_click", "mouse_move":
                return "\(c.name) at \(xy(c.coordinate))" + (c.text.map { " with \($0)" } ?? "")
            case "left_click_drag": return "left_click_drag from \(xy(c.startCoordinate)) to \(xy(c.coordinate))"
            case "scroll": return "scroll \(c.input["scroll_direction"] ?? "down") \(c.input["scroll_amount"] ?? 3) at \(xy(c.coordinate))"
            case "type": return "type \"\(short(c.text ?? "", 120))\""
            case "key": return "key \"\(c.text ?? "")\""
            case "hold_key": return "hold_key \"\(c.text ?? "")\" \(c.input["duration"] ?? 1)s"
            case "wait": return "wait \(c.input["duration"] ?? 1)s"
            default: return c.name
            }
        }
        switch c.name {
        case "open_app": return "open_app \"\(c.input["name"] as? String ?? "")\""
        case "open_url": return "open_url \"\(c.input["url"] as? String ?? "")\""
        case "run_applescript": return "run_applescript \"\(short(c.input["source"] as? String ?? "", 200))\""
        case "write_clipboard": return "write_clipboard \"\(short(c.input["text"] as? String ?? "", 120))\""
        case "report_progress": return "report_progress \"\(short(c.input["message"] as? String ?? "", 120))\""
        default: return c.name
        }
    }
}

// MARK: - Custom tools (non-computer)

enum AgentCustomTools {
    static let names: Set<String> = ["open_app", "open_url", "run_applescript", "read_clipboard", "write_clipboard", "report_progress"]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    /// Tool definitions sent alongside the computer toolset.
    static let definitions: [[String: Any]] = [
        tool("open_app", "Launch or bring to front a macOS application by name (e.g. \"Safari\", \"Notes\", \"Google Chrome\") or bundle identifier. Prefer this over Spotlight or the Dock. Returns the app's bundle identifier.",
             ["name": ["type": "string", "description": "Application name or bundle identifier"]], required: ["name"]),
        tool("open_url", "Open a URL in the user's default browser. Use this instead of typing into an address bar when the destination is known.",
             ["url": ["type": "string", "description": "Absolute URL (https://…)"]], required: ["url"]),
        tool("run_applescript", "Run an AppleScript and return its result as text. Useful for reading app state (e.g. the current Safari URL) or precise control of scriptable apps. 10 second timeout.",
             ["source": ["type": "string", "description": "AppleScript source code"]], required: ["source"]),
        tool("read_clipboard", "Return the current text contents of the clipboard.", [:], required: []),
        tool("write_clipboard", "Replace the clipboard contents with the given text.",
             ["text": ["type": "string", "description": "Text to place on the clipboard"]], required: ["text"]),
        tool("report_progress", "Tell the user what you are doing right now in one short sentence. Use sparingly, at meaningful milestones.",
             ["message": ["type": "string", "description": "One short sentence"]], required: ["message"]),
    ]

    // MARK: Execution

    /// Executes a custom tool. Throws `NaviError` on failure; returns result text.
    /// `activate == false` (background mode) opens apps and URLs without bringing them forward.
    static func execute(_ call: AgentToolCall, activate: Bool = true, emitStatus: @escaping @Sendable (String) -> Void) async throws -> String {
        switch call.name {
        case "open_app":
            guard let name = call.input["name"] as? String, !name.isEmpty else { throw NaviError.other("open_app: missing name") }
            return try await openApp(named: name, activate: activate)
        case "open_url":
            guard let raw = call.input["url"] as? String, !raw.isEmpty else { throw NaviError.other("open_url: missing url") }
            return try await openURL(raw, activate: activate)
        case "run_applescript":
            guard let src = call.input["source"] as? String, !src.isEmpty else { throw NaviError.other("run_applescript: missing source") }
            return try await runAppleScript(src, timeout: 10)
        case "read_clipboard":
            return await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
        case "write_clipboard":
            let text = call.input["text"] as? String ?? ""
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return "OK"
        case "report_progress":
            let msg = call.input["message"] as? String ?? ""
            if !msg.isEmpty { emitStatus(msg) }
            return "OK"
        default:
            throw NaviError.other("Unknown tool: \(call.name)")
        }
    }

    /// Launches (or, when `activate`, brings forward) the app. With
    /// `activate == false` — background mode — a running app is left where it
    /// is and a new one is launched behind the user's windows (`open -g`).
    static func openApp(named name: String, activate: Bool = true) async throws -> String {
        let url = await MainActor.run { findApp(named: name) }
        guard let url else {
            // Last resort: let LaunchServices resolve the name.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = (activate ? [] : ["-g"]) + ["-a", name]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NaviError.other("No application named \"\(name)\" was found") }
            return name
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? url.lastPathComponent
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try? await Task.sleep(for: .milliseconds(400))
        return bundleID
    }

    @MainActor
    static func findApp(named name: String) -> URL? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.contains("."), let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return u }
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        var apps: [URL] = []
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: nil) else { continue }
            apps += items.filter { $0.pathExtension == "app" }
        }
        func base(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }
        if let i = bestAppMatch(names: apps.map(base), wanted: q) { return apps[i] }
        let running = NSWorkspace.shared.runningApplications
        if let i = bestAppMatch(names: running.map { $0.localizedName ?? "" }, wanted: q), let u = running[i].bundleURL { return u }
        return nil
    }

    /// Index of the installed app `wanted` most plausibly names. Exact, then
    /// prefix, then substring, then a typo-tolerant match — dictated tasks
    /// arrive as "calculatorcul app" or "safar". Pure: testable.
    static func bestAppMatch(names: [String], wanted raw: String) -> Int? {
        var wanted = raw.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        if wanted.hasSuffix(" app") { wanted = String(wanted.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        wanted = wanted.replacingOccurrences(of: "the ", with: "", options: .anchored)
        guard wanted.count >= 2 else { return nil }
        let lower = names.map { $0.lowercased() }
        if let i = lower.firstIndex(of: wanted) { return i }
        if let i = lower.firstIndex(where: { !$0.isEmpty && $0.hasPrefix(wanted) }) { return i }
        if let i = lower.firstIndex(where: { !$0.isEmpty && $0.contains(wanted) }) { return i }
        // The name with extra letters tacked on ("calculatorcul" → Calculator), then edit distance.
        if wanted.count >= 4, let i = lower.indices.filter({ lower[$0].count >= 4 && wanted.hasPrefix(lower[$0]) }).max(by: { lower[$0].count < lower[$1].count }) { return i }
        let budget = max(1, wanted.count / 4)
        var best: (Int, Int)?
        for (i, n) in lower.enumerated() where !n.isEmpty && abs(n.count - wanted.count) <= budget {
            let d = editDistance(n, wanted)
            if d <= budget, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func openURL(_ raw: String, activate: Bool = true) async throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "maps", "file"].contains(scheme) else {
            throw NaviError.other("open_url: unsupported or malformed URL: \(raw)")
        }
        if activate {
            let ok = await MainActor.run { NSWorkspace.shared.open(url) }
            guard ok else { throw NaviError.other("open_url: macOS refused to open \(s)") }
        } else {
            // Background mode: the handler app must not come forward over the user's work.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            do { _ = try await NSWorkspace.shared.open(url, configuration: config) } catch {
                throw NaviError.other("open_url: macOS refused to open \(s)")
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        return "Opened \(s)"
    }

    private static let scriptQueue = DispatchQueue(label: "com.liamcarlin.navi.applescript")

    static func runAppleScript(_ source: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let done = NSLock()
            var resumed = false
            func finish(_ r: Result<String, Error>) {
                done.lock(); defer { done.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: r)
            }
            scriptQueue.async {
                guard let script = NSAppleScript(source: source) else {
                    finish(.failure(NaviError.other("Could not compile AppleScript"))); return
                }
                var err: NSDictionary?
                let desc = script.executeAndReturnError(&err)
                if let err {
                    let msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(err[NSAppleScript.errorNumber] ?? "")"
                    finish(.failure(NaviError.other(msg)))
                } else {
                    finish(.success(describe(desc)))
                }
            }
            // Timeout must run off the (blocked) script queue.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(NaviError.other("AppleScript timed out after \(Int(timeout)) s")))
            }
        }
    }

    private static func describe(_ d: NSAppleEventDescriptor) -> String {
        if let s = d.stringValue { return s }
        if d.numberOfItems > 0 {
            return (1...d.numberOfItems).compactMap { d.atIndex($0).map(describe) }.joined(separator: "\n")
        }
        return d.description
    }
}
