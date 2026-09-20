import AppKit
import ApplicationServices
import Foundation

/// Carries out one resolved `AgentAction` against the live screen.
///
/// Prefers Accessibility actions (`AXPress`, setting `AXValue`) because they
/// work even when the element is occluded and cost no key events; falls back
/// to CGEvent input via `InputController`.
final class ActionExecutor: @unchecked Sendable {
    private let input = InputController()

    static let refuseSecure = "Refusing to type into a secure/password field"

    func perform(_ action: AgentAction, text: String?, snapshot: AXSnapshot) async throws {
        switch action {
        case .click(let id):
            guard let el = snapshot.element(id) else { throw NaviError.other("Element \(id) is no longer on screen") }
            try await click(el)
        case .typeText(let id):
            guard let el = snapshot.element(id) else { throw NaviError.other("Element \(id) is no longer on screen") }
            guard let text, !text.isEmpty else { throw NaviError.other("No text to type") }
            try await type(text, into: el)
        case .select(let id, let option):
            guard let el = snapshot.element(id) else { throw NaviError.other("Element \(id) is no longer on screen") }
            try await select(option, in: el)
        case .scroll(let up):
            let p = snapshot.focusedElement?.center ?? snapshot.windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            await input.scroll(up ? .up : .down, amount: 5, at: p)
        case .wait:
            try await Task.sleep(for: .milliseconds(600))
        case .key(let combo):
            let k = try KeyCombo.parse(combo)
            if !snapshot.elements.isEmpty { await activate(pid: snapshot.pid) }
            await input.press(k)
        case .openApp(let name):
            _ = try await AgentCustomTools.openApp(named: name)
        case .openURL(let url):
            _ = try await AgentCustomTools.openURL(url)
        }
    }

    // MARK: Click

    func click(_ el: AXElement) async throws {
        if let ref = el.ref, el.hasPress {
            let err = await AXQueue.run { AXUIElementPerformAction(ref, kAXPressAction as CFString) }
            if err == .success {
                if el.isMenuBarItem { try? await Task.sleep(for: .milliseconds(120)) }
                return
            }
            Log.agent.debug("AXPress failed (\(err.rawValue)) on \(el.role, privacy: .public) — falling back to a click")
        }
        guard !el.frame.isEmpty else { throw NaviError.other("\(el.displayName) has no on-screen frame to click") }
        await activate(pid: el.pid)
        await input.click(at: el.center)
    }

    // MARK: Type

    func type(_ text: String, into el: AXElement) async throws {
        if el.isSecure { throw NaviError.other(Self.refuseSecure) }
        // Focus the field: AXFocused first (no pointer movement), else click it.
        var focused = false
        if let ref = el.ref {
            focused = await AXQueue.run { AXUIElementSetAttributeValue(ref, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }
        }
        if !focused { try await click(el) }
        try? await Task.sleep(for: .milliseconds(80))
        if InputController.focusedElementIsSecureField() { throw NaviError.other(Self.refuseSecure) }

        // Fast path: set AXValue directly when the app allows it, then verify.
        if let ref = el.ref, el.isTextInput {
            let ok = await AXQueue.run { () -> Bool in
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(ref, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
                guard AXUIElementSetAttributeValue(ref, kAXValueAttribute as CFString, text as CFTypeRef) == .success else { return false }
                return (AXSnapshotter.attr(ref, kAXValueAttribute) as? String) == text
            }
            if ok { return }
        }
        // Fallback: replace existing content by typing.
        if let v = el.value, !v.isEmpty { await input.press(KeyCombo(keyCode: 0, flags: .maskCommand, keyName: "a")) }
        await input.type(text)
    }

    /// Types into whatever currently has keyboard focus (used by the Claude fallback path too).
    func typeIntoFocus(_ text: String) async throws {
        if InputController.focusedElementIsSecureField() { throw NaviError.other(Self.refuseSecure) }
        await input.type(text)
    }

    // MARK: Select

    /// Opens a pop-up/combo box and presses the menu item titled `option`.
    func select(_ option: String, in el: AXElement) async throws {
        try await click(el)
        try? await Task.sleep(for: .milliseconds(150))
        let pressed: Bool = await AXQueue.run {
            guard let ref = el.ref else { return false }
            var queue: [AXUIElement] = AXSnapshotter.elements(AXSnapshotter.attr(ref, kAXChildrenAttribute)) ?? []
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let node = queue.removeFirst(); visited += 1
                let role = AXSnapshotter.attr(node, kAXRoleAttribute) as? String ?? ""
                let title = (AXSnapshotter.attr(node, kAXTitleAttribute) as? String)
                    ?? AXSnapshotter.stringValue(AXSnapshotter.attr(node, kAXValueAttribute)) ?? ""
                if (role == "AXMenuItem" || role == "AXRow" || role == "AXCell" || role == "AXStaticText"), title == option {
                    return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
                }
                queue += AXSnapshotter.elements(AXSnapshotter.attr(node, kAXChildrenAttribute)) ?? []
            }
            return false
        }
        if !pressed {
            await input.press(KeyCombo(keyCode: 53, flags: [], keyName: "escape"))
            throw NaviError.other("Could not find the option ‘\(option)’ in \(el.displayName)")
        }
    }

    // MARK: Helpers

    /// Brings `pid` to the front when it isn't already (CGEvent clicks land on the frontmost app).
    func activate(pid: pid_t) async {
        guard pid > 0 else { return }
        let switched: Bool = await MainActor.run {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
                  let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.activate()
        }
        if switched { try? await Task.sleep(for: .milliseconds(150)) }
    }
}

// MARK: - Task surface (browser vs native)

/// First step of every run: one Jev choice that decides whether the task
/// belongs in a browser (handed to `ComputerAgent.browserRunner` when one is
/// registered) or in a native macOS app (this driver).
enum TaskSurface {
    enum Surface: String, CaseIterable, Sendable { case browser, nativeApp = "native_app", unsure }

    static let criteria: [String: String] = [
        Surface.browser.rawValue: "Needs a website / web app / search engine / anything done inside a browser tab",
        Surface.nativeApp.rawValue: "Done inside a native macOS app (Finder, Mail, Xcode, Slack, Terminal…)",
        Surface.unsure.rawValue: "Cannot tell from the task alone",
    ]

    enum Start: String, Sendable { case currentTab = "current_tab", webSearch = "web_search" }

    static let questions: [String: JevClient.Question] = [
        "surface": .choice(instructions: "Where does this task have to be carried out?", criteria: criteria),
    ]

    /// Same call, second head: for browser tasks with no URL/site in the text,
    /// should the run start on the tab that's open now, or from a web search?
    static func questions(currentTab: (title: String, url: String)?) -> [String: JevClient.Question] {
        var q = questions
        if let t = currentTab {
            q["start_from"] = .choice(
                instructions: "The task will run in the browser. Should it start on the tab that is open right now, or from a fresh web search for the task?",
                criteria: [
                    Start.currentTab.rawValue: "The task is about, or continues work on, the page currently open: “\(t.title)” (\(t.url))",
                    Start.webSearch.rawValue: "The task needs to find something elsewhere on the web; the open page is unrelated",
                ])
        }
        return q
    }

    static func formatState(task: String, frontmost: FrontmostProbe.Info) -> String {
        JevDriver.serialize([
            "task": task,
            "frontmost_app": frontmost.appName ?? frontmost.bundleID ?? "unknown",
            "bundle": frontmost.bundleID ?? "",
            "window_title": frontmost.windowTitle ?? "",
            "url": frontmost.url ?? "",
            "frontmost_is_browser": frontmost.bundleID.map(AXSnapshotter.isBrowser) ?? false,
        ])
    }

    struct Classification: Sendable {
        var surface: Surface
        var confidence: Double
        var start: Start?          // only when a browser tab was open
    }

    // MARK: Prefetch (router → agent, before ⏎)

    private struct Prefetched: Sendable {
        var task: String
        var frontmost: FrontmostProbe.Info
        var classification: Classification
        var at: Date
    }
    private static let prefetchLock = NSLock()
    nonisolated(unsafe) private static var prefetched: Prefetched?
    nonisolated(unsafe) private static var inflight: Task<Void, Never>?
    /// A prefetched answer older than this is ignored (screen may have changed).
    static let prefetchTTL: TimeInterval = 90

    /// Classifies `task` in the background and remembers the answer for
    /// `classifyUsingPrefetch`. Cheap to call repeatedly: identical tasks
    /// coalesce, and `JevClient` caches identical requests anyway.
    @MainActor
    static func prefetch(task: String, jev: JevClient) {
        prefetchLock.lock()
        if let p = prefetched, p.task == task, Date().timeIntervalSince(p.at) < prefetchTTL { prefetchLock.unlock(); return }
        inflight?.cancel()
        prefetchLock.unlock()
        let front = FrontmostProbe.current(includeURL: true)
        let t = Task.detached(priority: .userInitiated) {
            let cls = await classify(task: task, frontmost: front, jev: jev)
            guard !Task.isCancelled else { return }
            prefetchLock.lock()
            prefetched = Prefetched(task: task, frontmost: front, classification: cls, at: Date())
            prefetchLock.unlock()
        }
        prefetchLock.lock(); inflight = t; prefetchLock.unlock()
    }

    /// The prefetched classification for `task` when there is a fresh one
    /// (waiting for an in-flight prefetch if needed); otherwise classifies now.
    static func classifyUsingPrefetch(task: String, jev: JevClient) async -> (FrontmostProbe.Info, Classification) {
        prefetchLock.lock()
        let t = inflight
        prefetchLock.unlock()
        if let t { await t.value }
        prefetchLock.lock()
        let hit = prefetched
        prefetchLock.unlock()
        if let hit, hit.task == task, Date().timeIntervalSince(hit.at) < prefetchTTL {
            Log.agent.debug("TaskSurface: using prefetched classification (\(hit.classification.surface.rawValue, privacy: .public))")
            return (hit.frontmost, hit.classification)
        }
        let front = await MainActor.run { FrontmostProbe.current(includeURL: true) }
        return (front, await classify(task: task, frontmost: front, jev: jev))
    }

    /// Never throws; unknown ⇒ `.unsure` so the native driver runs.
    static func classify(task: String, frontmost: FrontmostProbe.Info, jev: JevClient) async -> Classification {
        guard jev.isConfigured else { return Classification(surface: .unsure, confidence: 0, start: nil) }
        var tab: (String, String)? = nil
        if let b = frontmost.bundleID, AXSnapshotter.isBrowser(b), let u = frontmost.url, u.hasPrefix("http") {
            tab = (frontmost.windowTitle ?? "", u)
        }
        do {
            let r = try await jev.ask(state: formatState(task: task, frontmost: frontmost), questions: questions(currentTab: tab))
            guard let a = r["surface"], let c = a.choice, let s = Surface(rawValue: c) else {
                return Classification(surface: .unsure, confidence: 0, start: nil)
            }
            let start = r["start_from"]?.choice.flatMap(Start.init(rawValue:))
            return Classification(surface: s, confidence: a.confidence, start: start)
        } catch {
            return Classification(surface: .unsure, confidence: 0, start: nil)
        }
    }

    /// Where a browser task should start:
    ///   1. a URL written in the task;
    ///   2. a well-known site named in the task ("google flights", "amazon", …);
    ///   3. the current tab when Jev's `start_from` head chose it (or, without a
    ///      Jev answer, when the task refers to "this page"/"here" or names the tab's domain);
    ///   4. otherwise a Google search for the task, so Jev's first observation is a
    ///      results page full of relevant links rather than an unrelated tab.
    static func startURL(task: String, frontmost: FrontmostProbe.Info, start: Start? = nil) -> String? {
        if let u = TextCandidates.urls(in: task).first { return u.contains("://") ? u : "https://" + u }
        if let site = UltrafastBridge.knownSiteURL(in: task) { return site }
        let lower = task.lowercased()
        if let b = frontmost.bundleID, AXSnapshotter.isBrowser(b), let u = frontmost.url, u.hasPrefix("http") {
            if let start { return start == .currentTab ? u : UltrafastBridge.searchURL(for: task) }
            let refersToTab = ["this page", "this tab", "current page", "current tab", "here", "on this site", "this site"].contains { lower.contains($0) }
            let host = URL(string: u)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            let namesHost = !host.isEmpty && !host.hasPrefix("localhost") && lower.contains(host.split(separator: ".").first.map(String.init) ?? "\u{0}")
            if refersToTab || namesHost { return u }
        }
        return UltrafastBridge.searchURL(for: task)
    }
}
