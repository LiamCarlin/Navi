import AppKit
import ApplicationServices
import Foundation

// MARK: - Serial AX queue

/// Every Accessibility API call the agent makes goes through this one serial
/// queue: AX is IPC to the target app and is not meant to be hammered from
/// several threads at once.
enum AXQueue {
    static let queue = DispatchQueue(label: "com.liamcarlin.navi.ax", qos: .userInitiated)

    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async { cont.resume(returning: body()) }
        }
    }
}

// MARK: - Element

/// One actionable on-screen element, as Jev sees it. Constructible without a
/// live `AXUIElement` so ranking/formatting can be unit-tested.
struct AXElement: @unchecked Sendable {
    /// Stable within one snapshot: "e1", "e2", …
    var id: String
    var role: String
    var subrole: String?
    var label: String
    var value: String?
    /// Screen points, top-left origin (same space as `InputController` / CGEvent).
    var frame: CGRect
    var isFocused: Bool
    /// Up to three ancestor labels, e.g. "Sign-in form › Email".
    var path: String
    /// `AXUIElementCopyActionNames` result ("AXPress", "AXShowMenu", …).
    var actions: [String]
    /// Owning process (for activation before a CGEvent click).
    var pid: pid_t
    /// Enumerable options of a pop-up/combo box (SELECT targets); empty when unknown.
    var options: [String]
    /// Live reference; nil in tests.
    var ref: AXUIElement?

    init(id: String = "", role: String, subrole: String? = nil, label: String, value: String? = nil,
         frame: CGRect, isFocused: Bool = false, path: String = "", actions: [String] = [],
         pid: pid_t = 0, options: [String] = [], ref: AXUIElement? = nil) {
        self.id = id; self.role = role; self.subrole = subrole; self.label = label; self.value = value
        self.frame = frame; self.isFocused = isFocused; self.path = path; self.actions = actions
        self.pid = pid; self.options = options; self.ref = ref
    }

    /// Numeric index Jev sees ("e12" → 12).
    var index: Int { Int(id.dropFirst()) ?? 0 }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var hasPress: Bool { actions.contains("AXPress") }
    var isMenuBarItem: Bool { role == "AXMenuBarItem" }
    var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
    var isTextInput: Bool {
        ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
    }
    var isPopUp: Bool { role == "AXPopUpButton" || role == "AXComboBox" }

    /// Operations Jev may be offered for this element (jev-ultrafast vocabulary).
    var operations: [String] {
        var ops = ["CLICK"]
        if isTextInput, !isSecure { ops.append("TYPE_TEXT") }
        if isPopUp, !options.isEmpty { ops.append("SELECT") }
        return ops
    }

    /// Key used for de-duplication: role + label + frame rounded to the point.
    var dedupeKey: String {
        "\(role)|\(label)|\(Int(frame.minX.rounded()))|\(Int(frame.minY.rounded()))|\(Int(frame.width.rounded()))|\(Int(frame.height.rounded()))"
    }

    /// Short human name for step descriptions ("‘Sign in’", "the search field").
    var displayName: String {
        if !label.isEmpty { return "‘\(label)’" }
        switch role {
        case "AXTextField", "AXSearchField": return "the text field"
        case "AXTextArea": return "the text area"
        case "AXButton": return "the button"
        case "AXLink": return "the link"
        case "AXCheckBox": return "the checkbox"
        default: return "the \(role.dropFirst(2).lowercased())"
        }
    }
}

extension AXElement: Equatable {
    static func == (a: AXElement, b: AXElement) -> Bool {
        a.id == b.id && a.role == b.role && a.subrole == b.subrole && a.label == b.label && a.value == b.value
            && a.frame == b.frame && a.isFocused == b.isFocused && a.path == b.path && a.actions == b.actions && a.pid == b.pid
            && a.options == b.options
    }
}

// MARK: - Snapshot

/// What's actionable on screen right now, plus cheap text context so Jev can
/// tell whether the screen changed and whether the task is done.
struct AXSnapshot: @unchecked Sendable {
    var elements: [AXElement]
    var windowTitle: String?
    var url: String?
    var focused: String?              // element id
    var visibleText: String
    var capturedAt: Date
    var pid: pid_t
    var bundleID: String?
    var appName: String?
    var windowFrame: CGRect?

    static let cap = 120
    static let visibleTextCap = 1500
    static let maxDepth = 25
    static let nodeBudget = 4000
    /// Hard time box for one walk. Jev itself costs 220–500 ms, so observation must stay near zero.
    static let walkBudgetSeconds = 0.15

    /// Cheap fingerprint (focused app, window title, focused element role/value)
    /// used to detect that an action had an effect without a full walk.
    struct Fingerprint: Equatable, Sendable {
        var pid: pid_t
        var windowTitle: String
        var focusedRole: String
        var focusedValue: String
    }

    /// Does the task name a menu / menu-bar command? Only then is the menu bar walked.
    static func taskMentionsMenu(_ task: String) -> Bool {
        let t = task.lowercased()
        if t.contains("menu") || t.contains("→") || t.contains("->") { return true }
        return t.range(of: #"\b(file|edit|view|format|window|help|export|import|preferences|save as|print)\b"#, options: .regularExpression) != nil
    }

    init(elements: [AXElement], windowTitle: String? = nil, url: String? = nil, focused: String? = nil,
         visibleText: String = "", capturedAt: Date = Date(), pid: pid_t = 0, bundleID: String? = nil,
         appName: String? = nil, windowFrame: CGRect? = nil) {
        self.elements = elements; self.windowTitle = windowTitle; self.url = url; self.focused = focused
        self.visibleText = visibleText; self.capturedAt = capturedAt; self.pid = pid; self.bundleID = bundleID
        self.appName = appName; self.windowFrame = windowFrame
    }

    static let empty = AXSnapshot(elements: [])

    func element(_ id: String) -> AXElement? { elements.first { $0.id == id } }
    var focusedElement: AXElement? { focused.flatMap(element) }

    /// One-line description of what changed since `previous` ("12 new elements, title changed").
    func diff(previous: AXSnapshot?) -> String {
        guard let previous else { return "first snapshot" }
        var parts: [String] = []
        if previous.bundleID != bundleID, let appName { parts.append("app is now \(appName)") }
        if previous.windowTitle != windowTitle { parts.append("title changed") }
        if previous.url != url, url != nil || previous.url != nil { parts.append("url changed") }
        let before = Set(previous.elements.map(\.dedupeKey))
        let after = Set(elements.map(\.dedupeKey))
        let added = after.subtracting(before).count
        let removed = before.subtracting(after).count
        if added > 0 { parts.append("\(added) new element\(added == 1 ? "" : "s")") }
        if removed > 0 { parts.append("\(removed) element\(removed == 1 ? "" : "s") gone") }
        if previous.focusedElement?.dedupeKey != focusedElement?.dedupeKey {
            if let f = focusedElement { parts.append("focus on \(f.displayName)") } else if previous.focused != nil { parts.append("focus lost") }
        } else if let f = focusedElement, let pf = previous.focusedElement, f.value != pf.value {
            parts.append("focused value changed")
        }
        if previous.visibleText != visibleText, parts.isEmpty || (added == 0 && removed == 0) {
            parts.append("text changed")
        }
        return parts.isEmpty ? "no visible change" : parts.joined(separator: ", ")
    }

    // MARK: Ranking (pure, testable)

    /// Dedupe → cap → order: focused first, then reading order (rows of ~12 pt, then x).
    /// When more than `cap` elements exist, those inside the window and closest to
    /// `near` (the last acted-on frame) are kept.
    static func rank(_ input: [AXElement], windowFrame: CGRect?, near: CGRect?, cap: Int = cap) -> [AXElement] {
        var seen = Set<String>()
        var unique: [AXElement] = []
        for e in input where seen.insert(e.dedupeKey).inserted { unique.append(e) }

        var kept = unique
        if unique.count > cap {
            let anchor = near.map { CGPoint(x: $0.midX, y: $0.midY) }
            func priority(_ e: AXElement, _ index: Int) -> (Int, Double) {
                let inside = windowFrame.map { $0.intersects(e.frame) } ?? true
                let distance: Double = anchor.map { hypot(Double(e.center.x - $0.x), Double(e.center.y - $0.y)) } ?? Double(index)
                return (e.isFocused ? 0 : (inside ? 1 : 2), distance)
            }
            let ordered = unique.enumerated().sorted { a, b in
                let pa = priority(a.element, a.offset), pb = priority(b.element, b.offset)
                return pa.0 != pb.0 ? pa.0 < pb.0 : pa.1 < pb.1
            }
            kept = ordered.prefix(cap).map(\.element)
        }

        let sorted = kept.sorted { a, b in
            if a.isFocused != b.isFocused { return a.isFocused }
            let ra = Int((a.frame.minY / 12).rounded()), rb = Int((b.frame.minY / 12).rounded())
            if ra != rb { return ra < rb }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.label < b.label
        }
        return sorted.enumerated().map { i, e in var e = e; e.id = "e\(i + 1)"; return e }
    }
}

// MARK: - Capture

/// Walks the frontmost app's focused window through the Accessibility API and
/// returns the actionable candidates. Remembers which apps it has already
/// switched into "enhanced" AX mode so Chrome/Electron expose web content.
final class AXSnapshotter: @unchecked Sendable {
    private var preparedPIDs = Set<pid_t>()

    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXTab", "AXSlider",
        "AXDisclosureTriangle", "AXCell", "AXSecureTextField", "AXIncrementor", "AXColorWell", "AXDateField",
    ]
    /// Roles that count only when they expose AXPress.
    static let pressOnlyRoles: Set<String> = ["AXImage", "AXStaticText", "AXGroup", "AXRow", "AXUnknown", "AXHeading"]

    static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    /// Frontmost app + focused window → snapshot. Never throws; an app that
    /// exposes nothing yields an empty element list. `includeMenuBar` adds the
    /// app's top-level menu titles as candidates (costs ~10 IPC calls).
    func capture(near: CGRect?, includeMenuBar: Bool = false) async -> AXSnapshot {
        let front = await MainActor.run { () -> (pid_t?, String?, String?) in
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.processIdentifier, app?.bundleIdentifier, app?.localizedName)
        }
        guard let pid = front.0, pid != ProcessInfo.processInfo.processIdentifier else {
            return AXSnapshot(elements: [], bundleID: front.1, appName: front.2)
        }
        let bundleID = front.1
        if !preparedPIDs.contains(pid) {
            preparedPIDs.insert(pid)
            if Self.needsEnhancedUI(bundleID: bundleID) {
                await AXQueue.run { Self.enableEnhancedUI(pid: pid) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        var snap = await AXQueue.run { Self.walk(pid: pid, near: near, includeMenuBar: includeMenuBar) }
        snap.bundleID = bundleID
        snap.appName = front.2
        return snap
    }

    /// ~3 IPC calls; used to poll for "did anything change?" after an action.
    static func fingerprint() async -> AXSnapshot.Fingerprint? {
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid else { return nil }
        return await AXQueue.run {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var fp = AXSnapshot.Fingerprint(pid: pid, windowTitle: "", focusedRole: "", focusedValue: "")
            if let win = attr(app, kAXFocusedWindowAttribute) as! AXUIElement? {
                fp.windowTitle = attr(win, kAXTitleAttribute) as? String ?? ""
            }
            if let f = attr(app, kAXFocusedUIElementAttribute) as! AXUIElement? {
                fp.focusedRole = attr(f, kAXRoleAttribute) as? String ?? ""
                fp.focusedValue = String((stringValue(attr(f, kAXValueAttribute)) ?? "").prefix(80))
            }
            return fp
        }
    }

    /// Waits for the screen to react to an action: polls the cheap fingerprint
    /// every 40 ms and returns as soon as it differs from `before` (plus one
    /// extra tick so the change can finish), or after `maxMs`.
    static func settle(after before: AXSnapshot.Fingerprint?, maxMs: Int, minMs: Int = 80) async {
        let start = Date()
        var elapsed = 0
        while elapsed < maxMs {
            try? await Task.sleep(for: .milliseconds(40))
            elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if elapsed < minMs { continue }
            if let before, let now = await fingerprint(), now != before {
                try? await Task.sleep(for: .milliseconds(40))
                return
            }
        }
    }

    static func isBrowser(_ bundleID: String) -> Bool {
        bundleID == "com.apple.Safari" || chromiumBundles.contains(bundleID)
    }

    static func needsEnhancedUI(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if chromiumBundles.contains(bundleID) { return true }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let fw = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            if FileManager.default.fileExists(atPath: fw.path) { return true }
        }
        return false
    }

    static func enableEnhancedUI(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: Walk (runs on AXQueue)

    private struct Node {
        var element: AXUIElement
        var depth: Int
        var ancestors: [String]
    }

    static func walk(pid: pid_t, near: CGRect?, includeMenuBar: Bool) -> AXSnapshot {
        let deadline = Date().addingTimeInterval(AXSnapshot.walkBudgetSeconds)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)   // a hung app must not blow the time box

        var window: AXUIElement? = attr(app, kAXFocusedWindowAttribute) as! AXUIElement?
        if window == nil, let wins = elements(attr(app, kAXWindowsAttribute)), let first = wins.first { window = first }
        var snap = AXSnapshot(elements: [], pid: pid)
        var raw: [AXElement] = []
        var text: [String] = []
        var textLength = 0

        // Menu bar titles (skip the Apple menu) so "File → Export" style tasks work.
        if includeMenuBar, let bar = attr(app, kAXMenuBarAttribute) as! AXUIElement?, let items = elements(attr(bar, kAXChildrenAttribute)) {
            for item in items.dropFirst() {
                guard let role = attr(item, kAXRoleAttribute) as? String, role == "AXMenuBarItem" else { continue }
                let title = attr(item, kAXTitleAttribute) as? String ?? ""
                guard !title.isEmpty else { continue }
                raw.append(AXElement(role: role, label: title, frame: frame(of: item) ?? .zero,
                                     path: "Menu bar", actions: ["AXPress"], pid: pid, ref: item))
            }
        }

        guard let window else { return snap }
        snap.windowTitle = attr(window, kAXTitleAttribute) as? String
        let windowFrame = frame(of: window)
        snap.windowFrame = windowFrame

        var stack: [Node] = [Node(element: window, depth: 0, ancestors: [])]
        var visited = 0
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                          kAXEnabledAttribute, kAXFocusedAttribute, "AXFrame", kAXChildrenAttribute, kAXHiddenAttribute,
                          kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXTitleUIElementAttribute] as [String]

        while let node = stack.popLast() {
            if visited >= AXSnapshot.nodeBudget || Date() > deadline { break }
            visited += 1
            let el = node.element
            let vals = multiple(el, attributes)
            let role = vals[0] as? String ?? ""
            if (vals[9] as? Bool) == true { continue }                       // AXHidden
            if role == "AXWebArea", snap.url == nil, let u = stringValue(attr(el, "AXURL")), !u.isEmpty { snap.url = u }
            let f = rect(vals[7]) ?? frame(of: el)
            if let f, let wf = windowFrame, !f.isEmpty, !f.intersects(wf), node.depth > 0 { continue }  // scrolled off / other display
            let enabled = (vals[5] as? Bool) ?? true
            let title = (vals[2] as? String) ?? ""
            let desc = (vals[3] as? String) ?? ""
            let help = (vals[11] as? String) ?? ""
            let placeholder = (vals[10] as? String) ?? ""
            let value = stringValue(vals[4])
            var label = firstNonEmpty([title, desc, help])
            if label.isEmpty, let tue = vals[12], CFGetTypeID(tue as CFTypeRef) == AXUIElementGetTypeID() {
                label = (attr(tue as! AXUIElement, kAXValueAttribute) as? String) ?? (attr(tue as! AXUIElement, kAXTitleAttribute) as? String) ?? ""
            }
            let isText = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"].contains(role)
            if label.isEmpty, isText { label = placeholder.isEmpty ? String((value ?? "").prefix(60)) : placeholder }
            if label.isEmpty, role == "AXStaticText", let v = value { label = String(v.prefix(60)) }

            if role == "AXStaticText", let v = value, !v.isEmpty, textLength < AXSnapshot.visibleTextCap {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { text.append(t); textLength += t.count + 1 }
            }

            var actions: [String] = []
            let candidate: Bool
            if actionableRoles.contains(role) {
                candidate = true
                actions = actionNames(el)
            } else if pressOnlyRoles.contains(role) {
                actions = actionNames(el)
                candidate = actions.contains("AXPress")
            } else {
                candidate = false
            }
            if candidate, enabled, let f, !f.isEmpty, f.width >= 1, f.height >= 1, !(role == "AXStaticText" && label.isEmpty) {
                let focused = (vals[6] as? Bool) ?? false
                let path = node.ancestors.suffix(3).joined(separator: " › ")
                let shownValue: String? = (isText || role == "AXCheckBox" || role == "AXRadioButton" || role == "AXSlider"
                                           || role == "AXPopUpButton" || role == "AXComboBox" || role == "AXTab") ? value : nil
                let options = (role == "AXPopUpButton" || role == "AXComboBox") ? popUpOptions(el, children: elements(vals[8])) : []
                raw.append(AXElement(role: role, subrole: vals[1] as? String, label: label,
                                     value: role == "AXSecureTextField" ? "••••" : shownValue.map { String($0.prefix(60)) },
                                     frame: f, isFocused: focused, path: path, actions: actions, pid: pid, options: options, ref: el))
            }

            guard node.depth < AXSnapshot.maxDepth, let children = elements(vals[8]) else { continue }
            var ancestors = node.ancestors
            if !label.isEmpty, role != "AXStaticText", !isText { ancestors.append(String(label.prefix(30))) }
            // Push in reverse so the DFS visits children in their natural (reading) order.
            for child in children.reversed() { stack.append(Node(element: child, depth: node.depth + 1, ancestors: ancestors)) }
        }

        let ranked = AXSnapshot.rank(raw, windowFrame: windowFrame, near: near)
        snap.elements = ranked
        snap.focused = ranked.first(where: \.isFocused)?.id
        snap.visibleText = String(text.joined(separator: "\n").prefix(AXSnapshot.visibleTextCap))
        snap.capturedAt = Date()
        return snap
    }

    // MARK: AX helpers (queue-only)

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v
    }

    /// One IPC round trip for several attributes; missing/error entries become nil.
    static func multiple(_ el: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var arr: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &arr) == .success,
              let values = arr as? [AnyObject], values.count == names.count else {
            return names.map { attr(el, $0) }
        }
        return values.map { v in
            if CFGetTypeID(v) == CFNullGetTypeID() { return nil }
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func elements(_ v: AnyObject?) -> [AXUIElement]? {
        guard let arr = v as? [AnyObject] else { return nil }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func rect(_ v: AnyObject?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        guard AXValueGetType(ax) == .cgRect else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(ax, .cgRect, &r) ? r : nil
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        if let r = rect(attr(el, "AXFrame")) { return r }
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Titles of an already-exposed AXMenu/AXList under a pop-up (rare before the
    /// menu is opened, but some apps and web selects expose them). Cap 40.
    static func popUpOptions(_ el: AXUIElement, children: [AXUIElement]?) -> [String] {
        guard let children, !children.isEmpty else { return [] }
        var out: [String] = []
        for c in children {
            let role = attr(c, kAXRoleAttribute) as? String ?? ""
            let items = (role == "AXMenu" || role == "AXList") ? (elements(attr(c, kAXChildrenAttribute)) ?? []) : [c]
            for item in items {
                let r = attr(item, kAXRoleAttribute) as? String ?? ""
                guard r == "AXMenuItem" || r == "AXStaticText" || r == "AXRow" || r == "AXCell" else { continue }
                let t = (attr(item, kAXTitleAttribute) as? String) ?? stringValue(attr(item, kAXValueAttribute)) ?? ""
                if !t.isEmpty, !out.contains(t) { out.append(t) }
                if out.count >= 40 { return out }
            }
        }
        return out
    }

    static func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func stringValue(_ v: AnyObject?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    private static func firstNonEmpty(_ xs: [String]) -> String {
        for x in xs {
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }
}
