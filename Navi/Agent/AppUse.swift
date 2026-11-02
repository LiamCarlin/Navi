import Foundation

/// How *this* user works an app, read from the action journal (`ActionJournal`: every click,
/// menu pick and shortcut, at event rate — labels, never text) and from their routines. It is
/// what makes an app's manual grow with use: the commands they pick rank first when Jev is
/// offered them, their shortcuts and procedures go into the playbook the synthesizer writes,
/// and a learned recipe is theirs, not the model's guess.
///
/// Nothing new is recorded for this: the journal already has it. This only reads and
/// aggregates (counts per command and control, the routines' step lines), cached per app
/// for a few minutes. Under tests or with habits off there is no store and `AppUse` is empty.
struct AppUse: Equatable, Sendable {
    var bundleID: String
    /// Menu command (`AppManual.Command.full`, "File › Export…") → how often the user ran it,
    /// by menu or by its shortcut.
    var commands: [String: Int] = [:]
    /// Shortcut combo → the command it ran here ("cmd+shift+e" → "File › Export…"), for combos
    /// the user actually pressed.
    var shortcuts: [String: String] = [:]
    /// Control (role + label, "button ‘Add to cart’") → clicks.
    var controls: [String: Int] = [:]
    /// The user's own routines in this app, as step lines ("click button ‘New’ · type in ‘Title’ …"),
    /// newest first; what they were for.
    var routines: [(goal: String, steps: [String])] = []

    var isEmpty: Bool { commands.isEmpty && controls.isEmpty && routines.isEmpty }

    static func == (a: AppUse, b: AppUse) -> Bool {
        a.bundleID == b.bundleID && a.commands == b.commands && a.shortcuts == b.shortcuts && a.controls == b.controls
            && a.routines.map(\.goal) == b.routines.map(\.goal)
    }

    static let window: TimeInterval = 180 * 24 * 3600
    static let maxControls = 40
    static let maxRoutines = 8
    static let ttl: TimeInterval = 300

    // MARK: Build (pure)

    static func build(bundleID: String, actions: [ActionRecord], routines: [Routine]) -> AppUse {
        var use = AppUse(bundleID: bundleID)
        for a in actions where a.bundleID == bundleID {
            switch a.kind {
            case .menu, .key:
                guard !a.label.isEmpty else { continue }
                let full = (a.path.map { $0.isEmpty ? "" : $0 + AppManual.pathSeparator } ?? "") + a.label
                use.commands[full, default: 0] += 1
                if let s = a.shortcut, a.kind == .key || a.kind == .menu, s != "return" { use.shortcuts[s.lowercased()] = full }
            case .click:
                guard !a.label.isEmpty else { continue }
                use.controls["\(a.role) ‘\(a.label)’", default: 0] += 1
            case .type:
                continue
            }
        }
        if use.controls.count > maxControls {
            use.controls = Dictionary(uniqueKeysWithValues: use.controls.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxControls).map { ($0.key, $0.value) })
        }
        use.routines = routines.filter { $0.bundleID == bundleID && !$0.isDiscredited }
            .sorted { $0.last > $1.last }.prefix(maxRoutines)
            .map { (goal: $0.goals.first ?? $0.template, steps: $0.steps.map(\.human)) }
        return use
    }

    /// For the synthesizer's packet and Jev's playbook: compact, labels only.
    var state: [String: Any] {
        var d: [String: Any] = [:]
        let top = commands.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(20)
        if !top.isEmpty { d["commands_this_user_runs"] = top.map { ["command": $0.key, "times": $0.value] } }
        if !shortcuts.isEmpty { d["shortcuts_this_user_presses"] = shortcuts }
        let clicked = controls.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(20)
        if !clicked.isEmpty { d["controls_this_user_clicks"] = clicked.map { ["control": $0.key, "times": $0.value] } }
        if !routines.isEmpty { d["how_this_user_did_tasks_here"] = routines.map { ["task": $0.goal, "steps": $0.steps] } }
        return d
    }

    // MARK: Live

    nonisolated(unsafe) private static var cache: [String: (use: AppUse, at: Date)] = [:]
    private static let lock = NSLock()

    /// This user's use of an app, from screen memory; empty when there is none to read.
    static func live(bundleID: String?, now: Date = Date()) -> AppUse {
        guard let bundleID, !bundleID.isEmpty else { return AppUse(bundleID: "") }
        lock.lock()
        if let c = cache[bundleID], now.timeIntervalSince(c.at) < ttl { lock.unlock(); return c.use }
        lock.unlock()
        guard let moves = UserMoves.current else { return AppUse(bundleID: bundleID) }
        let actions = (try? moves.store.actions(bundleIDs: [bundleID], since: now.addingTimeInterval(-window))) ?? []
        let routines = UserRoutines.current?.routines(now: now) ?? []
        let use = build(bundleID: bundleID, actions: actions, routines: routines)
        lock.lock(); cache[bundleID] = (use, now); lock.unlock()
        return use
    }
}
