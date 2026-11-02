import AppKit
import ApplicationServices
import Foundation

/// The app's own manual, read from the app itself: every command in its menu bar with the
/// menu it sits in and its key equivalent. No model writes it and no playbook has to exist —
/// Fusion's Measure, Blender's Export, Affinity's Document Setup are all in there, and a
/// playbook app's manual completes what its author did not write down.
///
/// Read once per app version (`AppManualStore`, ~0.2–1 s on the AX queue, cached on disk in
/// Application Support), it rides into every native step: the commands whose titles or menus
/// carry the goal's words — the ones this user picks most first (`AppUse`) — are offered to
/// Jev as `press_offscreen` candidates ("menu item ‘File › Export…’"), pressed through AX
/// without opening the menu, with the shortcut as the fallback. The generic shortcut list is
/// re-described with what each combo does in this app, so the action set stays mutually
/// exclusive: a command with a generic combo is a shortcut, every other one an off-screen press.
///
/// Privacy: menu titles only. Items under Open Recent / recent lists and the window names at
/// the end of the Window menu are skipped (document names), Services too.
struct AppManual: Codable, Equatable, Sendable {
    struct Command: Codable, Equatable, Hashable, Sendable {
        var title: String
        /// The menus above it, top first ("File", "File › Export").
        var path: String
        /// Key equivalent in `KeyCombo.parse` spelling ("cmd+shift+e"), nil when none.
        var combo: String?

        /// "File › Export… ": the whole path, as Jev and the executor name it.
        var full: String { path.isEmpty ? title : path + " › " + title }
    }

    var bundleID: String
    var appName: String
    /// CFBundleShortVersionString at the time of reading; "" when unknown.
    var version: String
    /// Top-level menu titles, left to right (the Apple menu left out).
    var menus: [String]
    var commands: [Command]
    var readAt: Date
    /// The walk finished inside its budget; a partial manual is re-read next time.
    var complete: Bool

    static let maxCommands = 800
    static let maxDepth = 3
    static let maxTitleLength = 60
    static let walkBudget: TimeInterval = 1.2
    /// Commands offered to Jev in one step.
    static let offerLimit = 24
    /// Separator between menu titles in `path` / `full` (the journal's spelling).
    static let pathSeparator = " › "

    // MARK: Reading (AX; call on `AXQueue`)

    /// Walks the menu bar of a running app. Returns nil when the app shows no menu bar.
    static func read(pid: pid_t, bundleID: String, appName: String, version: String, now: Date = Date()) -> AppManual? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let barRef = AXSnapshotter.attr(app, "AXMenuBar"), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        let bar = barRef as! AXUIElement
        let deadline = now.addingTimeInterval(walkBudget)
        var menus: [String] = []
        var commands: [Command] = []
        var complete = true
        func children(_ el: AXUIElement) -> [AXUIElement] { AXSnapshotter.elements(AXSnapshotter.attr(el, kAXChildrenAttribute)) ?? [] }

        func walk(_ menu: AXUIElement, path: String, depth: Int, isWindowMenu: Bool) {
            var items: [(title: String, combo: String?, sub: AXUIElement?)] = []
            var lastSeparator = -1
            for item in children(menu) {
                if Date() > deadline || commands.count + items.count >= maxCommands { complete = false; break }
                let vals = AXSnapshotter.multiple(item, [kAXTitleAttribute, "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey"])
                let title = ((vals[0] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { lastSeparator = items.count; continue }   // a separator
                let combo = ActionJournal.menuCombo(char: vals[1] as? String, modifiers: (vals[2] as? NSNumber)?.intValue,
                                                    virtualKey: (vals[3] as? NSNumber)?.intValue)
                items.append((String(title.prefix(maxTitleLength)), combo, depth < maxDepth ? children(item).first : nil))
            }
            // The Window menu ends in the open windows' names (documents): stop at its last separator.
            let keep = isWindowMenu && lastSeparator > 0 ? Array(items.prefix(lastSeparator)) : items
            for it in keep {
                if skippedSubmenus.contains(it.title.lowercased().replacingOccurrences(of: "…", with: "")) { continue }
                commands.append(Command(title: it.title, path: path, combo: it.combo))
                if let sub = it.sub {
                    walk(sub, path: path.isEmpty ? it.title : path + pathSeparator + it.title, depth: depth + 1, isWindowMenu: false)
                }
            }
        }
        for top in children(bar).dropFirst() {   // the Apple menu is the system's
            if Date() > deadline { complete = false; break }
            let name = ((AXSnapshotter.attr(top, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            menus.append(name)
            if let menu = children(top).first { walk(menu, path: name, depth: 1, isWindowMenu: name.lowercased() == "window") }
        }
        return AppManual(bundleID: bundleID, appName: appName, version: version, menus: menus, commands: commands, readAt: now, complete: complete)
    }

    /// Submenus whose items are the user's own things, not the app's commands.
    static let skippedSubmenus: Set<String> = ["open recent", "recent", "recent files", "recent documents", "recent projects", "recents",
                                               "services", "reopen closed", "history", "bookmarks", "reading list"]

    /// Presses a command live: the item is found again by its titles (the manual may be older
    /// than the app's launch) and pressed through AX, which needs neither the menu open nor the
    /// app in front. nil when the item is not in the menu bar any more.
    static func press(full: String, pid: pid_t) -> Bool? {
        let titles = full.components(separatedBy: pathSeparator)
        guard !titles.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let barRef = AXSnapshotter.attr(app, "AXMenuBar"), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        func children(_ el: AXUIElement) -> [AXUIElement] { AXSnapshotter.elements(AXSnapshotter.attr(el, kAXChildrenAttribute)) ?? [] }
        func title(_ el: AXUIElement) -> String { ((AXSnapshotter.attr(el, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var current: AXUIElement? = nil
        var level = children(barRef as! AXUIElement)
        for (i, want) in titles.enumerated() {
            guard let hit = level.first(where: { title($0) == want }) ?? level.first(where: { title($0).hasPrefix(want) }) else { return nil }
            current = hit
            if i < titles.count - 1 {
                guard let menu = children(hit).first else { return nil }
                level = children(menu)
            }
        }
        guard let item = current else { return nil }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    // MARK: Relevance (pure)

    /// Words that name the same command in different apps: a goal that says one may find a
    /// menu item that says another.
    static let synonyms: [String: [String]] = [
        "export": ["export", "save as", "download", "publish", "render", "share"],
        "save": ["save", "export"],
        "download": ["download", "export", "save as"],
        "measure": ["measure", "dimension", "inspect", "distance", "ruler", "evaluate", "properties", "info"],
        "measurement": ["measure", "dimension", "inspect", "distance"],
        "new": ["new", "create", "add", "insert"],
        "create": ["new", "create", "add", "insert"],
        "make": ["new", "create", "add", "insert"],
        "add": ["add", "new", "insert", "create"],
        "insert": ["insert", "add", "new"],
        "delete": ["delete", "remove", "clear"],
        "remove": ["remove", "delete", "clear"],
        "rename": ["rename"],
        "open": ["open", "import"],
        "import": ["import", "open", "place"],
        "zoom": ["zoom", "fit", "actual size"],
        "fit": ["fit", "zoom"],
        "undo": ["undo"],
        "redo": ["redo"],
        "copy": ["copy", "duplicate"],
        "duplicate": ["duplicate", "copy"],
        "paste": ["paste"],
        "find": ["find", "search", "go to"],
        "search": ["search", "find"],
        "replace": ["replace"],
        "print": ["print"],
        "settings": ["settings", "preferences", "options"],
        "preferences": ["preferences", "settings"],
        "hide": ["hide", "show"],
        "show": ["show", "hide", "view"],
        "fullscreen": ["full screen", "fullscreen"],
        "full": ["full screen"],
        "screen": ["full screen"],
        "convert": ["convert", "export", "change"],
        "select": ["select", "select all"],
        "group": ["group"],
        "align": ["align", "distribute"],
        "rotate": ["rotate", "transform"],
        "flip": ["flip", "mirror"],
        "mirror": ["mirror", "flip"],
        "move": ["move", "transform", "translate"],
        "scale": ["scale", "transform", "resize"],
        "resize": ["resize", "scale", "size"],
        "crop": ["crop", "trim"],
        "trim": ["trim", "crop"],
        "split": ["split"],
        "merge": ["merge", "join", "combine", "union"],
        "join": ["join", "merge", "combine"],
        "comment": ["comment", "annotate", "note"],
        "annotate": ["annotate", "comment", "markup"],
        "sketch": ["sketch"],
        "extrude": ["extrude"],
        "revolve": ["revolve"],
        "fillet": ["fillet", "round"],
        "chamfer": ["chamfer"],
        "shell": ["shell"],
        "pattern": ["pattern", "array"],
        "assemble": ["assembly", "assemble", "mate", "joint"],
        "assembly": ["assembly", "assemble"],
        "part": ["part", "body", "component"],
        "drawing": ["drawing", "sheet"],
        "stl": ["stl", "export", "mesh", "3d print"],
        "step": ["step", "export"],
        "pdf": ["pdf", "export", "print"],
        "png": ["png", "export", "image"],
        "image": ["image", "picture", "png", "jpeg"],
        "video": ["video", "movie", "export"],
        "table": ["table"],
        "chart": ["chart", "graph"],
        "layer": ["layer"],
        "tab": ["tab"],
        "window": ["window"],
        "sidebar": ["sidebar"],
        "toolbar": ["toolbar"],
        "version": ["version", "history", "revision"],
        "history": ["history", "version"],
        "sync": ["sync", "upload"],
        "upload": ["upload", "sync", "share"],
        "share": ["share", "publish", "collaborate", "invite"],
        "invite": ["invite", "share", "collaborate"],
        "format": ["format", "style"],
        "style": ["style", "format"],
        "font": ["font", "text"],
        "color": ["color", "colour", "fill"],
        "colour": ["colour", "color"],
        "bold": ["bold"],
        "italic": ["italic"],
        "list": ["list", "bullet"],
        "link": ["link", "hyperlink"],
        "spell": ["spelling", "spell"],
        "word": ["word count", "count"],
        "count": ["count", "word count"],
        "play": ["play", "preview"],
        "preview": ["preview", "play"],
        "record": ["record", "capture"],
        "capture": ["capture", "screenshot", "record"],
        "screenshot": ["screenshot", "capture", "snapshot"],
        "snapshot": ["snapshot", "capture", "screenshot"],
        "unit": ["units", "unit"],
        "units": ["units", "unit", "document settings"],
        "grid": ["grid", "snap"],
        "snap": ["snap", "grid"],
    ]

    static let stopWords: Set<String> = AgentExperience.stopWords.union(["this", "that", "these", "those", "there", "here", "one",
                                                                          "thing", "what", "how", "which", "where", "when", "do", "does",
                                                                          "did", "be", "as", "an", "or", "by", "all", "any", "some", "just",
                                                                          "navi", "app", "file", "something", "it's", "its"])

    /// Content words of a goal, with their synonyms: what a command's title may say.
    static func terms(of goal: String) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for w in AgentExperience.words(goal) where !stopWords.contains(w) {
            var set: Set<String> = [w]
            if let syn = synonyms[w] { set.formUnion(syn) }
            // "exporting" / "exports" → export
            for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
                let stem = String(w.dropLast(suffix.count))
                set.insert(stem)
                if let syn = synonyms[stem] { set.formUnion(syn) }
            }
            out[w] = set
        }
        return out
    }

    /// How well a command answers the goal: words of the goal (or their synonyms) in its title
    /// count double, in its menu path once; a command this user picks here adds up to one point.
    /// A word of the command counts once however many goal words it stands for ("stl" and
    /// "export" both mean Export, but "File › Export › STL" says both and "File › Export…" one).
    /// 0 = nothing in common.
    static func score(_ c: Command, terms: [String: Set<String>], used: Int = 0) -> Double {
        let title = " " + c.title.lowercased().replacingOccurrences(of: "…", with: "") + " "
        let path = " " + c.path.lowercased() + " "
        var s = 0.0
        var credited = Set<String>()
        for (_, alts) in terms.sorted(by: { $0.key < $1.key }) {
            var best: (score: Double, word: String)?
            for a in alts where !credited.contains(a) {
                let needle = " " + a + " "
                if title.contains(needle) || (a.count >= 4 && title.contains(a)) {
                    if (best?.score ?? 0) < 2 { best = (2, a) }
                } else if path.contains(needle), (best?.score ?? 0) < 1 { best = (1, a) }
            }
            if let best { s += best.score; credited.insert(best.word) }
        }
        guard s > 0 else { return 0 }
        return s + min(1, Double(used) / 5)
    }

    /// The commands worth offering for this goal, best first, at most `limit`. `used`: how often
    /// this user picks each command here (`Command.full` → count), from the action journal.
    func commands(for goal: String, used: [String: Int] = [:], limit: Int = AppManual.offerLimit) -> [Command] {
        let terms = Self.terms(of: goal)
        guard !terms.isEmpty else { return [] }
        let scored: [(Command, Double, Int)] = commands.enumerated().compactMap { i, c in
            let s = Self.score(c, terms: terms, used: used[c.full] ?? 0)
            return s > 0 ? (c, s, i) : nil
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .filter { seen.insert($0.0.full).inserted }
            .prefix(limit).map(\.0)
    }

    // MARK: For Jev

    /// The generic shortcut list with what each combo does *in this app* ("cmd+n: New Sketch
    /// (Fusion)"), from the manual. Combos the app does not list keep their generic wording.
    func keyCombos(base: [(String, String)]) -> [(String, String)] {
        let byCombo = Dictionary(commands.compactMap { c in c.combo.map { ($0.lowercased(), c) } }, uniquingKeysWith: { a, _ in a })
        return base.map { combo, desc in
            guard let c = byCombo[combo.lowercased()] else { return (combo, desc) }
            return (combo, "\(c.full) (\(appName))")
        }
    }

    /// Commands as off-screen controls for the snapshot: the ones for this goal that are not
    /// already on the generic shortcut list (those are reached as shortcuts, so no command is
    /// offered twice), after the controls the walk found, ids renumbered.
    func offscreenElements(for goal: String, used: [String: Int], pid: pid_t, base: [(String, String)] = CUDecide.keyCombos) -> [AXElement] {
        let generic = Set(base.map { $0.0.lowercased() })
        return commands(for: goal, used: used).filter { c in c.combo.map { !generic.contains($0.lowercased()) } ?? true }.map { c in
            var e = AXElement(role: "AXMenuItem", label: c.full, frame: .zero, path: AppManual.menuBarPath,
                              actions: [AppManual.menuCommandAction], pid: pid)
            e.menuShortcut = c.combo
            return e
        }
    }

    /// `AXElement.path` of a manual command, and its pseudo action (`ActionExecutor` presses it by title).
    static let menuBarPath = "Menu bar"
    static let menuCommandAction = "NaviMenuCommand"

    /// The snapshot's off-screen list with this manual's commands for the goal appended (labels
    /// already there are not repeated), every id renumbered "o1", "o2", …
    static func merge(_ existing: [AXElement], commands: [AXElement]) -> [AXElement] {
        var seen = Set(existing.map { $0.label.lowercased() })
        let extra = commands.filter { seen.insert($0.label.lowercased()).inserted }
        return (existing + extra).enumerated().map { i, e in var e = e; e.id = "o\(i + 1)"; return e }
    }

    /// A few words about the app for Jev's state: its menus, so it knows the app's shape.
    var state: [String: Any] {
        ["app": appName, "menus": menus, "commands": commands.count]
    }
}

// MARK: - Store

/// Manuals by bundle id, in memory and on disk (`Application Support/Navi/manuals/`). One read
/// per app version; a partial read is retried on the next run.
final class AppManualStore: @unchecked Sendable {
    static let shared = AppManualStore()

    private let lock = NSLock()
    private var manuals: [String: AppManual] = [:]
    private var inFlight: Set<String> = []
    private let directory: URL?

    /// `directory: nil` keeps everything in memory (tests).
    init(directory: URL? = AppManualStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        TestHost.isActive ? nil : NaviSettings.dataDirectory.appendingPathComponent("manuals", isDirectory: true)
    }

    func manual(for bundleID: String?) -> AppManual? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let m = manuals[bundleID] { return m }
        guard let m = load(bundleID) else { return nil }
        manuals[bundleID] = m
        return m
    }

    func store(_ manual: AppManual) {
        lock.lock(); manuals[manual.bundleID] = manual; lock.unlock()
        save(manual)
    }

    /// The manual for a running app, read now if there is none for this version (or the last
    /// read ran out of time). Reads on the AX queue; nil for apps with no menu bar.
    @discardableResult
    func ensure(pid: pid_t, bundleID: String?, appName: String?) async -> AppManual? {
        guard let bundleID, !bundleID.isEmpty, pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let version = Self.version(pid: pid)
        if let m = manual(for: bundleID), m.version == version, m.complete { return m }
        lock.lock()
        let busy = !inFlight.insert(bundleID).inserted
        lock.unlock()
        if busy { return manual(for: bundleID) }
        defer { lock.lock(); inFlight.remove(bundleID); lock.unlock() }
        let name = appName ?? AppSkills.displayName(bundleID: bundleID)
        let read = await AXQueue.run { AppManual.read(pid: pid, bundleID: bundleID, appName: name, version: version) }
        guard let read, !read.commands.isEmpty else { return manual(for: bundleID) }
        Log.agent.info("AppManual: read \(name, privacy: .public) v\(version, privacy: .public): \(read.commands.count) commands in \(read.menus.count) menus\(read.complete ? "" : " (partial)", privacy: .public)")
        store(read)
        return read
    }

    static func version(pid: pid_t) -> String {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return "" }
        return (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
    }

    func removeAll() {
        lock.lock(); manuals = [:]; lock.unlock()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Disk

    private func fileURL(_ bundleID: String) -> URL? {
        directory?.appendingPathComponent(bundleID.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func load(_ bundleID: String) -> AppManual? {
        guard let url = fileURL(bundleID), let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(AppManual.self, from: data)
    }

    private func save(_ manual: AppManual) {
        guard let url = fileURL(manual.bundleID), let directory else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(manual) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch {
            Log.agent.error("AppManual: could not save \(manual.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
