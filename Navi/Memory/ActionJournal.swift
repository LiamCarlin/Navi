import AppKit
import ApplicationServices
import Foundation

/// How the user acts, not just what they look at: every control they click (the
/// button, link, row, tab, field or menu item under the pointer, read from the
/// accessibility tree) and every keyboard shortcut they press, with the app,
/// window and page it happened in. Screenshots say *what* was on screen; this says
/// *what the user did about it* — which is what the agent needs to act like them.
///
/// Feeds two things:
///   - the digester (`[ACTIONS]` in the prompt), which turns a session into a
///     procedure: the task, the steps the user took, how they work;
///   - `UserMoves` (Agent), which tells Jev every step which on-screen items this
///     user clicks here, what they click next, and the shortcuts they use.
///
/// Privacy: never what is typed — a key press is recorded only with ⌘ or ⌃ held (a
/// shortcut), and a text field is recorded by its label, never its value. Secure
/// fields, excluded apps, paused/off capture, Navi itself and apps whose current
/// screen triage marked sensitive are skipped; labels and titles go through
/// `PersonalData.redact`. Navi's own synthetic input carries `syntheticMarker`
/// (set by `InputController`) and is never learned from. Stored only in the local
/// memory database (`actions`, kept `MemoryStore.actionRetentionDays`).
final class ActionJournal: @unchecked Sendable {
    /// `CGEvent.eventSourceUserData` on every event Navi posts ("NAVI").
    static let syntheticMarker: Int64 = 0x4E41_5649
    /// Settings → Recall → "Learn how I work from my clicks and shortcuts".
    static let enabledKey = "memoryRecordActions"

    static let flushInterval: TimeInterval = 20
    static let flushCount = 25
    static let maxLabel = 80
    /// A double click, or the same control hit twice in a row, is one action.
    static let repeatWindow: TimeInterval = 1.0
    /// After a frame of this app was stored as a sensitive stub, its clicks are not
    /// recorded for this long (or until a normal frame of it arrives).
    static let sensitiveHold: TimeInterval = 120
    /// Pointer travel (pt) below which a mouse-down/up pair is a click, not a drag.
    static let clickSlop: CGFloat = 6

    let store: MemoryStore

    private let queue = DispatchQueue(label: "com.liamcarlin.navi.memory.journal", qos: .utility)
    // Main actor only.
    private var monitors: [Any] = []
    private var downAt: CGPoint?
    // Queue only.
    private var buffer: [ActionRecord] = []
    private var lastFlush = Date()
    private var lastAction: (key: String, at: Date)?
    private var urlByPID: [pid_t: (url: String, at: Date)] = [:]
    private var menuCache: [pid_t: (items: [MenuShortcut], at: Date)] = [:]
    private var accessibilityAsked: Set<pid_t> = []
    // Any thread.
    private let lock = NSLock()
    private var inFlight = 0
    nonisolated(unsafe) private static var sensitiveUntil: [String: Date] = [:]
    private static let sensitiveLock = NSLock()

    init(store: MemoryStore) { self.store = store }

    // MARK: Config

    struct Config: Sendable {
        var enabled: Bool
        var excluded: Set<String>
        var policy: PersonalData.Policy
    }

    @MainActor static var config: Config {
        let s = NaviSettings.shared
        return Config(enabled: s.memoryCaptureEnabled && !s.memoryIsPaused && s.memoryRecordActions,
                      excluded: Set(s.memoryExcludedBundleIDs), policy: s.personalDataPolicy)
    }

    // MARK: Sensitive screens (integration hook for `CaptureScheduler`)

    /// The app's current screen was triaged sensitive (banking, a password page):
    /// what the user clicks there is not recorded for a while.
    static func noteSensitive(bundleID: String, now: Date = Date()) {
        sensitiveLock.withLock { sensitiveUntil[bundleID] = now.addingTimeInterval(sensitiveHold) }
    }

    /// A normal frame of the app arrived: its clicks count again.
    static func noteNormal(bundleID: String) {
        sensitiveLock.withLock { _ = sensitiveUntil.removeValue(forKey: bundleID) }
    }

    static func isHeldSensitive(_ bundleID: String, now: Date = Date()) -> Bool {
        sensitiveLock.withLock { (sensitiveUntil[bundleID] ?? .distantPast) > now }
    }

    // MARK: Start / stop

    @MainActor func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(m)
            Log.memory.info("Action journal started")
        } else {
            Log.memory.warning("Action journal: no event monitor (Accessibility not granted?)")
        }
    }

    @MainActor func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        if !monitors.isEmpty { Log.memory.info("Action journal stopped") }
        monitors.removeAll()
        queue.async { self.flush(force: true) }
    }

    // MARK: Events (main actor: read cheaply, hand off)

    @MainActor private func handle(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return }
        let cfg = Self.config
        guard cfg.enabled else { return }
        let now = Date()
        switch event.type {
        case .leftMouseDown:
            guard let p = event.cgEvent?.location else { return }
            downAt = p
            enqueue { $0.recordClick(at: p, menuOnly: false, cfg: cfg, now: now) }
        case .leftMouseUp:
            // A press dragged onto a menu item and released there chooses it (no mouse-down on the item).
            guard let p = event.cgEvent?.location, let d = downAt else { return }
            downAt = nil
            if hypot(p.x - d.x, p.y - d.y) > Self.clickSlop {
                enqueue { $0.recordClick(at: p, menuOnly: true, cfg: cfg, now: now) }
            }
        case .keyDown:
            guard !event.isARepeat, let combo = Self.combo(keyCode: event.keyCode, flags: event.modifierFlags),
                  let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
                  let bundle = app.bundleIdentifier, !cfg.excluded.contains(bundle) else { return }
            let pid = app.processIdentifier, name = app.localizedName ?? bundle
            enqueue { $0.recordKey(combo, pid: pid, bundleID: bundle, appName: name, cfg: cfg, now: now) }
        default: break
        }
    }

    /// Runs `work` on the journal queue; drops it when the queue is backed up (a hung app).
    private func enqueue(_ work: @escaping (ActionJournal) -> Void) {
        let ok = lock.withLock { () -> Bool in
            guard inFlight < 16 else { return false }
            inFlight += 1; return true
        }
        guard ok else { return }
        queue.async { [self] in
            work(self)
            lock.withLock { inFlight -= 1 }
        }
    }

    // MARK: Recording (queue)

    private func recordClick(at p: CGPoint, menuOnly: Bool, cfg: Config, now: Date) {
        guard let hit = Self.hitTest(p), hit.pid != getpid(),
              let app = NSRunningApplication(processIdentifier: hit.pid), let bundle = app.bundleIdentifier,
              !cfg.excluded.contains(bundle), !Self.isHeldSensitive(bundle, now: now) else { return }
        guard let c = Self.control(from: hit.element) else {
            enableWebAccessibility(pid: hit.pid, bundleID: bundle)
            return
        }
        if menuOnly, c.axRole != "AXMenuItem" { return }
        if let u = c.url { urlByPID[hit.pid] = (u, now) }
        guard let label = Self.clean(c.label, policy: cfg.policy) else { return }
        let rec = ActionRecord(timestamp: now, bundleID: bundle, appName: app.localizedName ?? bundle,
                               windowTitle: c.windowTitle.flatMap { Self.clean($0, policy: cfg.policy, max: 120) },
                               url: (c.url ?? recentURL(pid: hit.pid, now: now)).flatMap(UserHabits.cleanURL),
                               kind: c.axRole == "AXMenuItem" ? .menu : .click, role: c.role, label: label,
                               shortcut: c.shortcut, path: c.path.flatMap { Self.clean($0, policy: cfg.policy, max: 60) })
        append(rec, now: now)
    }

    private func recordKey(_ combo: String, pid: pid_t, bundleID: String, appName: String, cfg: Config, now: Date) {
        guard !Self.isHeldSensitive(bundleID, now: now), !Self.ignoredCombos.contains(combo) else { return }
        let menu = menuItem(for: combo, pid: pid, now: now)
        let rec = ActionRecord(timestamp: now, bundleID: bundleID, appName: appName,
                               windowTitle: Self.focusedWindowTitle(pid: pid).flatMap { Self.clean($0, policy: cfg.policy, max: 120) },
                               url: recentURL(pid: pid, now: now).flatMap(UserHabits.cleanURL),
                               kind: .key, role: "", label: menu.flatMap { Self.clean($0.title, policy: cfg.policy) } ?? "",
                               shortcut: combo, path: menu?.path)
        append(rec, now: now)
    }

    private func append(_ rec: ActionRecord, now: Date) {
        let key = "\(rec.bundleID)|\(rec.kind.rawValue)|\(rec.role)|\(rec.label)|\(rec.shortcut ?? "")"
        if let last = lastAction, last.key == key, now.timeIntervalSince(last.at) < Self.repeatWindow, rec.kind != .key { return }
        lastAction = (key, now)
        buffer.append(rec)
        flush(force: false)
    }

    private func flush(force: Bool) {
        guard !buffer.isEmpty else { return }
        guard force || buffer.count >= Self.flushCount || Date().timeIntervalSince(lastFlush) > Self.flushInterval else { return }
        let batch = buffer
        buffer.removeAll()
        lastFlush = Date()
        do { try store.insertActions(batch) } catch {
            Log.memory.error("Action journal: could not save \(batch.count) actions: \(error.localizedDescription)")
        }
    }

    private func recentURL(pid: pid_t, now: Date) -> String? {
        guard let u = urlByPID[pid], now.timeIntervalSince(u.at) < 600 else { return nil }
        return u.url
    }

    /// Chromium and Electron build their web accessibility tree only when asked; without it
    /// a click in a page hits one opaque area. Asked once per process (the agent asks too).
    private func enableWebAccessibility(pid: pid_t, bundleID: String) {
        guard !accessibilityAsked.contains(pid), FrameCapture.browserBundleIDs.contains(bundleID) || bundleID.contains("electron") else { return }
        accessibilityAsked.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: Accessibility reading

    struct Hit { var element: AXUIElement; var pid: pid_t }

    static func hitTest(_ p: CGPoint) -> Hit? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, let el else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid > 0 else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.25)
        return Hit(element: el, pid: pid)
    }

    /// What was clicked, as the user would name it.
    struct Control: Equatable {
        var axRole: String
        var role: String
        var label: String
        var shortcut: String?
        var path: String?
        var windowTitle: String?
        var url: String?
    }

    /// Roles that are something to click. A plain group or text counts only when it takes AXPress.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTab", "AXDisclosureTriangle", "AXRow", "AXCell", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXSlider", "AXIncrementor", "AXDockItem", "AXColorWell",
    ]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    /// Opening a menu is the way to its item, which is recorded on its own.
    static let skippedRoles: Set<String> = ["AXMenuBarItem", "AXMenuBar", "AXMenu", "AXScrollBar", "AXSplitter", "AXWindow", "AXApplication"]

    /// The nearest clickable ancestor (≤ 8 levels up) of the element under the pointer.
    static func control(from start: AXUIElement) -> Control? {
        var cur: AXUIElement? = start
        var depth = 0
        var found: (AXUIElement, String, String?)?
        while let el = cur, depth < 8 {
            let role = AXSnapshotter.attr(el, kAXRoleAttribute) as? String ?? ""
            let subrole = AXSnapshotter.attr(el, kAXSubroleAttribute) as? String
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return nil }
            if skippedRoles.contains(role) { return nil }
            if actionableRoles.contains(role) || (role != "AXWebArea" && pressable(el)) { found = (el, role, subrole); break }
            cur = parent(el); depth += 1
        }
        guard let (el, axRole, subrole) = found else { return nil }

        let title = AXSnapshotter.attr(el, kAXTitleAttribute) as? String ?? ""
        let desc = AXSnapshotter.attr(el, kAXDescriptionAttribute) as? String ?? ""
        let help = AXSnapshotter.attr(el, kAXHelpAttribute) as? String ?? ""
        var label = [title, desc, help].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        if label.isEmpty, textRoles.contains(axRole) {
            label = (AXSnapshotter.attr(el, kAXPlaceholderValueAttribute) as? String) ?? ""   // never the value
        }
        if label.isEmpty, !textRoles.contains(axRole) { label = AXSnapshotter.descendantLabel(el) }
        guard !label.isEmpty else { return nil }

        var c = Control(axRole: axRole, role: roleWord(axRole, subrole: subrole), label: label)
        if axRole == "AXMenuItem" {
            c.shortcut = menuCombo(char: AXSnapshotter.attr(el, "AXMenuItemCmdChar") as? String,
                                   modifiers: (AXSnapshotter.attr(el, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                                   virtualKey: (AXSnapshotter.attr(el, "AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue)
            c.path = menuPath(of: el)
        } else {
            c.path = containerLabel(of: el)
        }
        if let w = AXSnapshotter.attr(el, kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            c.windowTitle = AXSnapshotter.attr(w as! AXUIElement, kAXTitleAttribute) as? String
        }
        c.url = webAreaURL(above: el)
        return c
    }

    static func roleWord(_ axRole: String, subrole: String?) -> String {
        if subrole == "AXTabButton" { return "tab" }
        if axRole == "AXRow" || axRole == "AXCell" { return "row" }
        let w = CURoles.word(axRole)
        return w == "other" ? "control" : w
    }

    private static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let p = AXSnapshotter.attr(el, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }

    private static func pressable(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains("AXPress")
    }

    /// "File", "Format › Font": the menu bar item (and submenu) a menu item sits in.
    private static func menuPath(of item: AXUIElement) -> String? {
        var names: [String] = []
        var cur = parent(item)
        var depth = 0
        while let el = cur, depth < 6 {
            let role = AXSnapshotter.attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXMenuBarItem" || role == "AXMenuItem", let t = AXSnapshotter.attr(el, kAXTitleAttribute) as? String, !t.isEmpty {
                names.insert(t, at: 0)
            }
            if role == "AXMenuBarItem" || role == "AXApplication" { break }
            cur = parent(el); depth += 1
        }
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }

    /// The first named container above a control ("Toolbar", "Message list"), ≤ 6 levels up.
    private static func containerLabel(of el: AXUIElement) -> String? {
        var cur = parent(el)
        var depth = 0
        while let c = cur, depth < 6 {
            let role = AXSnapshotter.attr(c, kAXRoleAttribute) as? String ?? ""
            if ["AXWindow", "AXWebArea", "AXApplication"].contains(role) { return nil }
            let t = (AXSnapshotter.attr(c, kAXTitleAttribute) as? String) ?? ""
            let d = (AXSnapshotter.attr(c, kAXDescriptionAttribute) as? String) ?? ""
            if let name = [t, d].first(where: { !$0.isEmpty }) { return String(name.prefix(40)) }
            cur = parent(c); depth += 1
        }
        return nil
    }

    /// The page a web control is on: the enclosing AXWebArea's AXURL.
    private static func webAreaURL(above el: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        var depth = 0
        while let c = cur, depth < 40 {
            let role = AXSnapshotter.attr(c, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" {
                if let u = AXSnapshotter.attr(c, "AXURL") { return (u as? URL)?.absoluteString ?? (u as? String) ?? (u as? NSURL)?.absoluteString }
                return nil
            }
            if role == "AXWindow" || role == "AXApplication" { return nil }
            cur = parent(c); depth += 1
        }
        return nil
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let w = AXSnapshotter.attr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return AXSnapshotter.attr(w as! AXUIElement, kAXTitleAttribute) as? String
    }

    // MARK: Menu shortcuts (what a pressed shortcut does)

    struct MenuShortcut: Equatable, Sendable {
        var title: String
        var path: String
        var combo: String
    }

    /// The menu item a shortcut triggers in this app ("cmd+r" → Message › Reply), from its
    /// menu bar read once per 15 minutes. nil for shortcuts no menu shows (web apps' own keys).
    private func menuItem(for combo: String, pid: pid_t, now: Date) -> MenuShortcut? {
        if menuCache[pid] == nil || now.timeIntervalSince(menuCache[pid]!.at) > 900 {
            menuCache[pid] = (Self.menuShortcuts(pid: pid), now)
        }
        guard let want = try? KeyCombo.parse(combo) else { return nil }
        return menuCache[pid]?.items.first { (try? KeyCombo.parse($0.combo)).map { $0.keyCode == want.keyCode && $0.flags == want.flags } ?? false }
    }

    /// Every menu item with a key equivalent (two levels deep), within a small time box.
    static func menuShortcuts(pid: pid_t) -> [MenuShortcut] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AXSnapshotter.attr(app, "AXMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        let deadline = Date().addingTimeInterval(0.6)
        var out: [MenuShortcut] = []
        func children(_ el: AXUIElement) -> [AXUIElement] { AXSnapshotter.elements(AXSnapshotter.attr(el, kAXChildrenAttribute)) ?? [] }
        func walk(_ menu: AXUIElement, path: String, depth: Int) {
            for item in children(menu) where Date() < deadline && out.count < 400 {
                let vals = AXSnapshotter.multiple(item, [kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey"])
                let title = (vals[0] as? String) ?? ""
                if !title.isEmpty, let combo = menuCombo(char: vals[1] as? String, modifiers: (vals[2] as? NSNumber)?.intValue,
                                                         virtualKey: (vals[3] as? NSNumber)?.intValue) {
                    out.append(MenuShortcut(title: title, path: path, combo: combo))
                }
                if depth < 1, !title.isEmpty, let sub = children(item).first {
                    walk(sub, path: path + " › " + title, depth: depth + 1)
                }
            }
        }
        for top in children(bar as! AXUIElement).dropFirst() where Date() < deadline {   // the Apple menu is the system's
            let name = (AXSnapshotter.attr(top, kAXTitleAttribute) as? String) ?? ""
            if let menu = children(top).first { walk(menu, path: name, depth: 0) }
        }
        return out
    }

    // MARK: Pure helpers

    /// Shortcuts that say nothing about how the user works in an app.
    static let ignoredCombos: Set<String> = ["cmd+space", "cmd+tab", "cmd+shift+tab", "ctrl+space"]

    /// Virtual key → the name `KeyCombo.parse` reads back.
    static let keyNames: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        for (name, code) in KeyCombo.keyCodes where name.count == 1 && name != " " { out[UInt16(code)] = name }
        let special: [String] = ["return", "tab", "space", "backspace", "delete", "escape", "home", "end", "page_up", "page_down",
                                 "left", "right", "down", "up", "kp_enter", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9",
                                 "f10", "f11", "f12"]
        for name in special { if let code = KeyCombo.keyCodes[name] { out[UInt16(code)] = name } }
        return out
    }()

    /// "cmd+shift+t" for a key press with ⌘ or ⌃ held; nil for plain typing (never recorded).
    static func combo(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) || f.contains(.control), let key = keyNames[keyCode] else { return nil }
        var parts: [String] = []
        if f.contains(.command) { parts.append("cmd") }
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("option") }
        if f.contains(.shift) { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }

    /// A menu item's key equivalent as a combo. AXMenuItemCmdModifiers: 1 shift, 2 option,
    /// 4 control, 8 no command. nil when the item has none.
    static func menuCombo(char: String?, modifiers: Int?, virtualKey: Int?) -> String? {
        var key: String?
        var shift = false
        if let ch = char?.trimmingCharacters(in: .whitespacesAndNewlines), !ch.isEmpty, ch.count == 1, ch.unicodeScalars.first!.value >= 0x20 {
            let lower = ch.lowercased()
            if let base = KeyCombo.shifted[ch], KeyCombo.keyCodes[base] != nil { key = base; shift = true }   // "?" → shift+slash
            else if KeyCombo.keyCodes[lower] != nil { key = lower }
        } else if let vk = virtualKey, vk > 0, let name = keyNames[UInt16(vk)] {
            key = name
        }
        guard let key else { return nil }
        let m = modifiers ?? 0
        var parts: [String] = []
        if m & 8 == 0 { parts.append("cmd") }
        if m & 4 != 0 { parts.append("ctrl") }
        if m & 2 != 0 { parts.append("option") }
        if m & 1 != 0 || shift { parts.append("shift") }
        guard !parts.isEmpty else { return nil }
        return (parts + [key]).joined(separator: "+")
    }

    /// One line, capped, blocked personal identifiers removed; nil when nothing is left.
    static func clean(_ s: String, policy: PersonalData.Policy, max: Int = maxLabel) -> String? {
        let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = one.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let redacted = PersonalData.redact(collapsed, policy: policy).text
        let out = String(redacted.prefix(max)).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }

    /// "Reply (cmd+r)", "click button ‘New Email’", for prompts and notes.
    static func describe(_ a: ActionRecord) -> String {
        let label = a.label.isEmpty ? nil : "‘\(a.label)’"
        switch a.kind {
        case .key:
            return "press \(a.shortcut ?? "?")" + (label.map { " → \($0)" + (a.path.map { " in \($0) menu" } ?? "") } ?? "")
        case .menu:
            return "menu " + ([a.path, a.label].compactMap { $0 }.joined(separator: " › ")) + (a.shortcut.map { " (\($0))" } ?? "")
        case .click:
            return "click \(a.role) \(label ?? "")" + (a.path.map { " in \($0)" } ?? "")
        }
    }

    /// Prompt lines for a stretch of actions: "10:02 Outlook · click button ‘Reply’", repeats
    /// folded ("×3"), at most `max` lines (the most recent kept when there are more).
    static func lines(_ actions: [ActionRecord], max: Int = 40, calendar: Calendar = .current) -> [String] {
        let time = DateFormatter()
        time.calendar = calendar; time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        var out: [(at: String, head: String, body: String, n: Int)] = []
        var lastPlace = ""
        for a in actions {
            let place = UserHabits.siteKey(of: a.url ?? "") ?? a.appName
            let body = describe(a)
            if let last = out.last, last.body == body, place == lastPlace { out[out.count - 1].n += 1; continue }
            out.append((time.string(from: a.timestamp), place == lastPlace ? "" : "\(place) · ", body, 1))
            lastPlace = place
        }
        return out.suffix(max).map { "\($0.at) \($0.head)\($0.body)" + ($0.n > 1 ? " ×\($0.n)" : "") }
    }
}
