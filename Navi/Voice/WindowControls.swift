import AppKit
import ApplicationServices
import Foundation

/// App- and window-level instructions — "close out of this", "quit Messages",
/// "close out of the calculator", "hide Slack", "minimize this", "full screen" —
/// recognised locally and carried out directly: `NSRunningApplication.terminate`,
/// the window's own close / minimize / full-screen attributes. No agent, no Jev
/// step, no writer.
///
/// They were a quarter of all spoken tasks in the run logs (2026-09-29/30), and
/// every one went through the computer-use loop: Jev found no "quit" control,
/// pressed ⌘W five times in QuickTime, and the writer then refused ("quitting an
/// app is something only you should do"). Pure matching, unit-tested; the
/// executor acts.
enum WindowControls {
    enum Verb: String, Sendable {
        /// Close the front window (in a browser: the tab, which is what "close this" means there).
        case closeWindow
        case quit, hide, minimize, fullScreen
    }

    enum Target: Equatable, Sendable {
        /// "this", "that", "it", "the window", or nothing: whatever the user is looking at.
        case front
        /// A running app, by its display name ("Messages", "Superwhisper").
        case app(String)
    }

    struct Command: Equatable, Sendable {
        var verb: Verb
        var target: Target

        /// Shown in the island: "Quitting Messages", "Closing the window".
        var title: String {
            let name: String? = { if case .app(let n) = target { return n }; return nil }()
            switch verb {
            case .closeWindow: return "Closing the window"
            case .quit: return "Quitting \(name ?? "the app")"
            case .hide: return "Hiding \(name ?? "the app")"
            case .minimize: return "Minimizing the window"
            case .fullScreen: return "Toggling full screen"
            }
        }
    }

    /// Words said before the instruction that carry nothing ("wait, close…", "no, quit",
    /// "I can you close out of that"). Only stripped from the front.
    static let leading: Set<String> = ["wait", "no", "okay", "ok", "um", "uh", "so", "hey", "navi", "please", "can", "could",
                                       "would", "will", "you", "i", "just", "now", "and", "then", "go", "ahead", "actually", "also"]
    /// Words around the object that never name an app.
    static let filler: Set<String> = ["the", "this", "that", "it", "a", "an", "of", "out", "up", "app", "application", "window",
                                      "for", "me", "please", "now", "real", "quick", "quickly", "all", "the", "way", "too",
                                      "right", "current", "front", "frontmost", "one"]
    /// Objects that are part of an app, not an app: "close the sidebar" is the agent's job.
    static let notApps: Set<String> = ["tab", "tabs", "sidebar", "dialog", "popup", "pop", "menu", "panel", "sheet", "document",
                                       "file", "note", "message", "email", "chat", "conversation", "page", "folder", "pane",
                                       "inspector", "modal", "banner", "notification", "preview", "video", "call", "meeting",
                                       "draft", "box", "bar", "search", "settings", "preferences", "thread", "project"]

    /// (spoken verb, what it does, whether a named app is required). Longest first.
    static let verbs: [(words: [String], verb: Verb, needsApp: Bool)] = [
        (["force", "quit"], .quit, false),
        (["quit", "out", "of"], .quit, false),
        (["exit", "out", "of"], .quit, false),
        (["close", "out", "of"], .closeWindow, false),
        (["close", "out"], .closeWindow, false),
        (["get", "out", "of"], .closeWindow, false),
        (["shut", "down"], .quit, true),
        (["quit"], .quit, false),
        (["exit"], .quit, false),
        (["kill"], .quit, true),
        (["close"], .closeWindow, false),
        (["hide"], .hide, false),
        (["minimize"], .minimize, false),
        (["minimise"], .minimize, false),
        (["go", "full", "screen"], .fullScreen, false),
        (["make", "it", "full", "screen"], .fullScreen, false),
        (["make", "this", "full", "screen"], .fullScreen, false),
        (["full", "screen"], .fullScreen, false),
        (["fullscreen"], .fullScreen, false),
        (["exit", "full", "screen"], .fullScreen, false),
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    /// The command `text` asks for, if it is one and nothing more. `resolveApp` maps a spoken
    /// name to a running app's display name (nil when no running app has that name): a name
    /// that resolves to nothing makes the whole clause not a window command — "close the
    /// draft" belongs to the agent.
    static func match(_ text: String, resolveApp: (String) -> String?) -> Command? {
        var w = words(text)
        while let f = w.first, leading.contains(f), w.count > 1 { w.removeFirst() }
        guard !w.isEmpty, w.count <= 9 else { return nil }
        // "exit full screen" before "exit": try the longest verb that fits.
        for entry in verbs.sorted(by: { $0.words.count > $1.words.count }) where w.starts(with: entry.words) {
            var rest = Array(w.dropFirst(entry.words.count))
            if entry.verb == .fullScreen {
                return rest.allSatisfy({ filler.contains($0) || $0 == "mode" }) ? Command(verb: .fullScreen, target: .front) : nil
            }
            rest = rest.filter { !filler.contains($0) }
            // "…for me", "…please" at the end were filler; anything else names the object.
            if rest.isEmpty {
                guard !entry.needsApp else { return nil }
                return Command(verb: entry.verb, target: .front)
            }
            guard rest.count <= 3, !rest.contains(where: notApps.contains) else { return nil }
            let spoken = rest.joined(separator: " ")
            guard let app = resolveApp(spoken) else { return nil }
            // "close Messages" means the app is done with, not one of its windows.
            let verb: Verb = entry.verb == .closeWindow ? .quit : entry.verb
            return Command(verb: verb, target: .app(app))
        }
        return nil
    }

    // MARK: Running apps

    /// Lower-cased letters and digits only: "Super Whisper" and "Superwhisper" meet.
    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The display name among `names` that `spoken` names: equal once squashed, one starts with
    /// the other, or the name's last words ("chrome" → Google Chrome, "outlook" → Microsoft
    /// Outlook). Partial matches need ≥ 4 letters; the shortest name wins.
    static func bestName(_ spoken: String, in names: [String]) -> String? {
        let s = squash(spoken)
        guard s.count >= 3 else { return nil }
        if let exact = names.first(where: { squash($0) == s }) { return exact }
        guard s.count >= 4 else { return nil }
        return names.filter { n in
            let q = squash(n)
            if q.count >= 4, q.hasPrefix(s) || s.hasPrefix(q) { return true }
            let w = n.split(separator: " ")
            return w.count > 1 && (1..<w.count).contains { squash(w[$0...].joined()) == s }
        }.min { squash($0).count < squash($1).count }
    }

    /// Regular (Dock) apps that are running, Navi excluded.
    @MainActor
    static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != AgentTarget.selfPID }
            .compactMap(\.localizedName)
    }

    // MARK: Perform

    /// Carries out `command`. `fallbackApp` is the app the previous instruction worked in, used
    /// for "this" when Navi itself is in front. Returns what was done, or a failure message.
    @MainActor
    static func perform(_ command: Command, fallbackApp: String?, input: InputController) async -> Result<String, NaviError> {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != AgentTarget.selfPID }
        let app: NSRunningApplication?
        switch command.target {
        case .app(let name):
            app = apps.first { $0.localizedName == name } ?? apps.first { bestName(name, in: [$0.localizedName ?? ""]) != nil }
        case .front:
            if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != AgentTarget.selfPID { app = f }
            else { app = apps.first { $0.bundleIdentifier == fallbackApp || $0.localizedName == fallbackApp } }
        }
        guard let app else {
            if case .app(let n) = command.target { return .failure(.other("\(n) isn't running")) }
            return .failure(.other("No app is in front to \(command.verb == .quit ? "quit" : "act on")"))
        }
        let name = app.localizedName ?? "the app"
        let pid = app.processIdentifier
        switch command.verb {
        case .quit:
            guard app.terminate() else { return .failure(.other("\(name) refused to quit")) }
            // Most apps are gone within a few hundred ms; one with unsaved work asks first — that's fine.
            for _ in 0..<10 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(60)) }
            return .success(app.isTerminated ? "Quit \(name)" : "Asked \(name) to quit")
        case .hide:
            app.hide()
            return .success("Hid \(name)")
        case .closeWindow:
            // A browser's "this" is the tab; ⌘W there closes the tab, not the whole window of tabs.
            if let b = app.bundleIdentifier, AXSnapshotter.isBrowser(b) {
                if NSWorkspace.shared.frontmostApplication != app {
                    app.activate()
                    try? await Task.sleep(for: .milliseconds(200))
                }
                await input.press(KeyCombo(keyCode: 13, flags: .maskCommand, keyName: "w"))
                return .success("Closed the tab")
            }
            let pressed = await AXQueue.run { () -> Bool in
                guard let win = AgentTarget.axWindow(pid: pid) else { return false }
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &ref) == .success, let b = ref else { return false }
                return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
            }
            if pressed { return .success("Closed the \(name) window") }
            // No close button (a borderless or custom window): the app's own ⌘W.
            if NSWorkspace.shared.frontmostApplication != app {
                app.activate()
                try? await Task.sleep(for: .milliseconds(200))
            }
            await input.press(KeyCombo(keyCode: 13, flags: .maskCommand, keyName: "w"))
            return .success("Closed the \(name) window")
        case .minimize, .fullScreen:
            let attribute = command.verb == .minimize ? kAXMinimizedAttribute as String : "AXFullScreen"
            let ok = await AXQueue.run { () -> Bool in
                guard let win = AgentTarget.axWindow(pid: pid) else { return false }
                var cur: CFTypeRef?
                let now = AXUIElementCopyAttributeValue(win, attribute as CFString, &cur) == .success && (cur as? Bool ?? false)
                let next: CFBoolean = command.verb == .minimize ? kCFBooleanTrue : (now ? kCFBooleanFalse : kCFBooleanTrue)
                return AXUIElementSetAttributeValue(win, attribute as CFString, next) == .success
            }
            guard ok else { return .failure(.other("\(name) has no window to \(command.verb == .minimize ? "minimize" : "make full screen")")) }
            return .success(command.verb == .minimize ? "Minimized \(name)" : "Toggled full screen in \(name)")
        }
    }
}
