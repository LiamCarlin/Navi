import Foundation

// Routines: what screen memory keeps about *how* the user gets things done, in a form the
// agent can carry out. A procedure (`Digester`) says it in words ("Slack: click 'Haakon
// Olsen' in Direct Messages, cmd+return to send"); a routine is the same thing as the
// controls themselves — the app or page, the control's role, label and container, the
// shortcut, where they typed and how they sent it — so the agent can find each one again
// on the live screen and press it without asking a model (`UserRoutines`, Agent).
//
// Mined locally from `procedures` + `actions`, never by a model: the digester names the
// task and (since this change) which recorded actions did it (`ProcedureRecord.actionIDs`);
// older procedures are aligned to the journal by the control names their steps quote. The
// part of a step that changes between runs — the person, the assignment, the document —
// is a *slot*: the words a label shares with its goal ("Haakon Olsen" in "message Haakon
// Olsen on Slack"). Routines with the same steps up to their slots are one routine done
// several times (`count`). `worked`/`failed` count how the agent fared following it.

/// One step of a routine, as the agent can find it on screen again.
struct RoutineStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Bring an app forward (a Dock click): `label` is the app.
        case open
        case click
        /// A menu item chosen with the mouse (`path` is its menu, `shortcut` its key equivalent).
        case menu
        case key
        /// Type into the field `label` (what is typed comes from the task, never from memory).
        case type
        /// How what was typed is sent: Return, ⌘Return… (`shortcut`), right after `type`.
        case submit
    }

    var kind: Kind
    var app: String
    var bundleID: String
    /// Site key of the page it happened on (`UserHabits.siteKey`), nil in a native app.
    var site: String?
    /// The page with its ids folded ("canvas.olin.edu/courses/#/assignments").
    var page: String?
    /// The journal's role word ("button", "link", "row", "field").
    var role: String = ""
    /// The control's label as the user saw it in the newest example.
    var label: String = ""
    var path: String?
    var shortcut: String?
    /// The label's words that are this run's particular person / item / document: the
    /// part that changes between runs ("haakon olsen"). nil for a fixed control.
    var slot: String?
    /// How many of the user's routines take this same fixed step (a navigation control they
    /// use for many tasks — "Assignments", "Show more" — not one particular item). nil: unknown.
    var seen: Int?

    /// The label without its slot words, lower-cased: what every run of the routine shows.
    var fixedLabel: String {
        guard let slot else { return RoutineMiner.norm(label) }
        let drop = Set(RoutineMiner.tokens(slot))
        return RoutineMiner.tokens(label).filter { !drop.contains($0) }.joined(separator: " ")
    }

    /// "click link ‘Assignments’", "type in ‘Message to …’" — for Jev, the planner and the vault.
    var human: String {
        let shown = slot.map { s in "‘" + Self.blanked(label, slot: s) + "’" } ?? "‘\(label)’"
        let place = path.map { " in \($0)" } ?? ""
        switch kind {
        case .open: return "open \(label)"
        case .click: return "click \(role.isEmpty ? "" : role + " ")\(shown)\(place)"
        case .menu: return "menu \([path, label].compactMap { $0 }.joined(separator: " › "))" + (shortcut.map { " (\($0))" } ?? "")
        case .key: return "press \(shortcut ?? "?")" + (label.isEmpty ? "" : " (\(label))")
        case .type: return "type in \(shown)"
        case .submit: return "send with \(shortcut ?? "Return")"
        }
    }

    /// "Message to Haakon Olsen" with slot "haakon olsen" → "Message to …".
    static func blanked(_ label: String, slot: String) -> String {
        let drop = Set(RoutineMiner.tokens(slot))
        var out: [String] = []
        for w in label.split(separator: " ").map(String.init) {
            let isSlot = RoutineMiner.tokens(w).contains(where: drop.contains)
            if isSlot { if out.last != "…" { out.append("…") } } else { out.append(w) }
        }
        return out.joined(separator: " ")
    }
}

/// A way the user does one kind of task, from one or more digested sessions.
struct Routine: Equatable, Sendable {
    /// Stable identity: the place and the steps up to their slots (`RoutineMiner.key`).
    var key: String
    /// The tasks it did, newest first (≤ `RoutineMiner.maxGoals`).
    var goals: [String]
    /// The newest goal with its slot words as "…" ("message … on Slack").
    var template: String
    var bundleID: String
    var appName: String
    var site: String?
    /// The page the newest example started on (a clean URL), for a browser start.
    var startURL: String?
    var steps: [RoutineStep]
    var count: Int
    var first: Date
    var last: Date
    var worked = 0
    var failed = 0

    /// The agent tried it and it went wrong more often than right: not offered any more.
    var isDiscredited: Bool { failed >= 2 && failed > worked }
    /// Every step's words that change between runs.
    var slotWords: Set<String> { Set(steps.compactMap(\.slot).flatMap(RoutineMiner.tokens)) }
}

enum RoutineMiner {
    static let maxSteps = 12
    static let maxGoals = 5
    /// A gap this long between two kept actions ends the routine (the rest is another task).
    static let maxGap: TimeInterval = 15 * 60

    // MARK: Words

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
    }

    static func norm(_ s: String) -> String { tokens(s).joined(separator: " ") }

    /// Words of a task that name no particular thing: verbs, kinds of things, app and site words.
    static let generic: Set<String> = [
        "open", "go", "send", "message", "messages", "text", "email", "mail", "reply", "respond", "forward", "write", "draft", "new",
        "create", "make", "add", "remove", "delete", "edit", "update", "change", "set", "view", "review", "check", "see", "look",
        "read", "find", "search", "show", "get", "access", "start", "submit", "share", "upload", "download", "copy", "paste",
        "click", "select", "choose", "navigate", "complete", "finish", "do", "work", "working", "continue", "join", "call", "schedule",
        "assignment", "assignments", "course", "courses", "class", "document", "doc", "docs", "file", "files", "folder", "page", "site",
        "repository", "repo", "chat", "conversation", "thread", "dm", "team", "group", "channel", "meeting", "event", "calendar",
        "note", "notes", "task", "tasks", "project", "settings", "inbox", "tab", "window", "app", "website", "link", "list", "item",
        "about", "regarding", "their", "his", "her", "them", "with", "from", "into", "onto", "using", "via", "all", "some",
        "first", "last", "next", "previous", "latest", "recent", "today", "tomorrow", "yesterday", "week", "this", "that", "these",
        "a", "an", "the", "to", "in", "on", "of", "for", "and", "then", "my", "me", "it", "is", "at", "up", "by", "or",
        "slack", "outlook", "gmail", "canvas", "github", "google", "chrome", "safari", "discord", "whatsapp", "imessage", "claude",
        "drive", "sheets", "forms", "notion", "linkedin", "zoom", "teams", "onshape", "terminal", "finder", "web",
    ]

    /// Words of a text that name something particular: not verbs, kinds of things or app names.
    static func specificWords(_ text: String) -> Set<String> {
        Set(tokens(text).filter { !generic.contains($0) && ($0.count >= 3 || $0.contains(where: \.isNumber)) })
    }

    /// The words of a goal that can be a slot: names and codes the way the goal writes them —
    /// capitalised past its first word ("Haakon Olsen", "Phase 1 Strategy Review") or holding a
    /// digit ("MTH3199", "03") — never a kind of thing ("survey", "collaborator").
    static func slotWords(_ goal: String) -> Set<String> {
        var out = Set<String>()
        let words = goal.split(whereSeparator: { $0.isWhitespace })
        for (i, w) in words.enumerated() {
            let named = (i > 0 && w.first?.isUppercase == true) || w.contains(where: \.isNumber)
            guard named else { continue }
            for t in tokens(String(w)) where !generic.contains(t) && (t.count >= 3 || t.contains(where: \.isNumber)) { out.insert(t) }
        }
        return out
    }

    // MARK: Actions → steps

    /// Keys that edit text or manage tabs and windows: how the user moved around, not a step
    /// of the task (the agent opens its own tab and types its own text).
    static let incidentalKeys: Set<String> = Set([
        "cmd+left", "cmd+right", "cmd+up", "cmd+down", "cmd+backspace", "cmd+delete", "cmd+a", "cmd+z", "cmd+shift+z",
        "cmd+c", "cmd+x", "cmd+v", "cmd+shift+v", "cmd+option+v", "cmd+w", "cmd+shift+w", "cmd+t", "cmd+shift+t", "cmd+`", "cmd+shift+`",
        "cmd+r", "cmd+shift+r", "cmd+l", "cmd+q", "cmd+h", "cmd+m", "ctrl+tab", "ctrl+shift+tab", "cmd+option+left",
        "cmd+option+right", "cmd+shift+[", "cmd+shift+]", "cmd+[", "cmd+]", "cmd+=", "cmd+-", "cmd+0", "cmd+f", "cmd+g",
        "cmd+shift+g", "cmd+s", "escape", "ctrl+a", "ctrl+e", "ctrl+k", "cmd+i", "cmd+b", "cmd+u",
    ]).union((1...9).map { "cmd+\($0)" })
    /// Keys that send what was just typed.
    static let submitKeys: Set<String> = ["return", "kp_enter", "cmd+return", "cmd+kp_enter", "shift+return", "ctrl+return", "option+return"]
    /// Apps whose clicks are never part of a task.
    static let incidentalBundles: Set<String> = ["com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.WindowManager",
                                                 "com.apple.systemuiserver", "com.apple.Spotlight", "com.liamcarlin.navi"]
    static let dockBundle = "com.apple.dock"
    /// Clicks that go back on the click before them.
    static let backLabels: Set<String> = ["back", "go back", "previous page"]

    /// The steps a stretch of the user's actions took toward `goal`, cleaned: text edits, tab
    /// juggling and incidental clicks dropped, a click undone by Back dropped with it, a field
    /// click folded into the typing it started, repeats folded, slots found.
    static func steps(from actions: [ActionRecord], goal: String) -> [RoutineStep] {
        build(from: actions, goal: goal).steps
    }

    /// `steps`, plus the clean URL of the page the first one was taken on.
    static func build(from actions: [ActionRecord], goal: String, place: String? = nil) -> (steps: [RoutineStep], startURL: String?) {
        var out: [RoutineStep] = []
        var urls: [String?] = []
        var lastAt: Date?
        for a in actions.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let t = lastAt, a.timestamp.timeIntervalSince(t) > maxGap, !out.isEmpty { break }
            guard !incidentalBundles.contains(a.bundleID) else { continue }
            let site = a.url.flatMap(UserHabits.siteKey(of:))
            let page = a.url.flatMap(pagePattern)
            var step: RoutineStep
            switch a.kind {
            case .key:
                guard let combo = a.shortcut?.lowercased() else { continue }
                if submitKeys.contains(combo) {
                    // Return only sends when it follows typing; elsewhere it is an Enter press.
                    if out.last?.kind == .type { step = RoutineStep(kind: .submit, app: a.appName, bundleID: a.bundleID, site: site, page: page, shortcut: combo) }
                    else if combo == "return" { continue }
                    else { step = RoutineStep(kind: .key, app: a.appName, bundleID: a.bundleID, site: site, page: page, label: a.label, path: a.path, shortcut: combo) }
                } else if incidentalKeys.contains(combo) {
                    if browserBack(combo, bundleID: a.bundleID), let last = out.last, last.kind == .click { out.removeLast(); urls.removeLast() }
                    continue
                } else {
                    step = RoutineStep(kind: .key, app: a.appName, bundleID: a.bundleID, site: site, page: page, label: a.label, path: a.path, shortcut: combo)
                }
            case .menu:
                if let s = a.shortcut?.lowercased(), incidentalKeys.contains(s) { continue }
                step = RoutineStep(kind: .menu, app: a.appName, bundleID: a.bundleID, site: site, page: page, role: "menu item",
                                   label: a.label, path: a.path, shortcut: a.shortcut)
            case .type:
                if let last = out.last, last.kind == .type, norm(last.label) == norm(a.label) { lastAt = a.timestamp; continue }
                step = RoutineStep(kind: .type, app: a.appName, bundleID: a.bundleID, site: site, page: page, role: "field", label: a.label, path: a.path)
            case .click:
                guard !a.label.isEmpty else { continue }
                if a.bundleID == dockBundle {
                    step = RoutineStep(kind: .open, app: a.label, bundleID: "", label: a.label)
                } else if backLabels.contains(norm(a.label)) {
                    if let last = out.last, last.kind == .click { out.removeLast(); urls.removeLast() }
                    continue
                } else if a.role == "field" {
                    // Clicking a field is how typing into it starts (typing itself is not in older journals).
                    step = RoutineStep(kind: .type, app: a.appName, bundleID: a.bundleID, site: site, page: page, role: "field", label: a.label, path: a.path)
                    if let last = out.last, last.kind == .type, norm(last.label) == norm(a.label) { lastAt = a.timestamp; continue }
                } else {
                    step = RoutineStep(kind: .click, app: a.appName, bundleID: a.bundleID, site: site, page: page, role: a.role,
                                       label: a.label, path: a.path, shortcut: a.shortcut)
                }
            }
            // The same step twice in a row is one step (a double click, a retried button).
            if let last = out.last, last.kind == step.kind, norm(last.label) == norm(step.label), last.shortcut == step.shortcut, last.bundleID == step.bundleID { lastAt = a.timestamp; continue }
            out.append(step)
            urls.append(a.url)
            lastAt = a.timestamp
        }
        // Opening an app as the last thing: nothing to replay.
        while let last = out.last, last.kind == .open { out.removeLast(); urls.removeLast() }
        // Clicks elsewhere before the work began (another tab, another app) are not part of it:
        // the routine starts at its own place (or at the app opened right before it).
        if let place, let first = out.firstIndex(where: { ($0.site ?? $0.bundleID) == place || $0.bundleID == place }), first > 0 {
            let from = out[first - 1].kind == .open ? first - 1 : first
            out.removeFirst(from); urls.removeFirst(from)
        }
        let named = slotWords(goal)
        let steps = Array(out.prefix(maxSteps)).map { s in
            var s = s
            guard s.kind != .open, s.kind != .key, s.kind != .submit else { return s }
            let shared = tokens(s.label).filter { named.contains($0) }
            if !shared.isEmpty { s.slot = shared.joined(separator: " ") }
            return s
        }
        let start = zip(steps, urls).first { $0.0.site != nil }?.1.flatMap(UserHabits.cleanURL)
        return (steps, start)
    }

    /// ⌘← / ⌘[ in a browser outside a text field is Back.
    static func browserBack(_ combo: String, bundleID: String) -> Bool {
        (combo == "cmd+left" || combo == "cmd+[") && FrameCapture.browserBundleIDs.contains(bundleID)
    }

    // MARK: Prose steps → actions (procedures from before `action_ids`)

    /// The actions a procedure's written steps name, in order: each quoted control name
    /// ('Reply', ‘Assignments’) and each shortcut (cmd+return) is matched to the next
    /// recorded action that carries it.
    static func align(steps: [String], actions: [ActionRecord]) -> [ActionRecord] {
        let pattern = #"'([^']{2,80})'|‘([^’]{2,80})’|"([^"]{2,80})"|\b((?:cmd|ctrl|option|shift)(?:\+[a-z0-9`\-=\[\];,./\\]+)+)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let sorted = actions.sorted { $0.timestamp < $1.timestamp }
        var out: [ActionRecord] = []
        var i = 0
        for line in steps {
            let ns = line as NSString
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                func group(_ g: Int) -> String? { m.range(at: g).location == NSNotFound ? nil : ns.substring(with: m.range(at: g)) }
                if let combo = group(4)?.lowercased() {
                    if let j = sorted[i...].firstIndex(where: { $0.shortcut?.lowercased() == combo }) { out.append(sorted[j]); i = j + 1 }
                } else if let quoted = group(1) ?? group(2) ?? group(3) {
                    let want = norm(quoted)
                    guard !want.isEmpty else { continue }
                    if let j = sorted[i...].firstIndex(where: { a in
                        let have = norm(a.label)
                        return !have.isEmpty && (have == want || have.hasPrefix(want) || (want.count >= 12 && want.hasPrefix(have)))
                    }) { out.append(sorted[j]); i = j + 1 }
                }
                if i >= sorted.count { return out }
            }
        }
        return out
    }

    // MARK: Pages

    /// A page with its ids folded, so every course or assignment page is one page:
    /// "https://canvas.olin.edu/courses/1083/assignments/20412" → "canvas.olin.edu/courses/#/assignments/#".
    /// At most four path segments; opaque tokens (session ids, hashes) are ids too.
    static func pagePattern(_ url: String) -> String? {
        guard let site = UserHabits.siteKey(of: url), let u = URLComponents(string: url) else { return nil }
        let host = site.split(separator: "/").first.map(String.init) ?? site
        let segs = u.path.split(separator: "/").prefix(4).map { s -> String in
            let seg = String(s)
            let isID = seg.allSatisfy(\.isNumber) || seg.count >= 20
                || (seg.count >= 8 && seg.contains(where: \.isNumber) && seg.contains(where: \.isLetter) && !seg.contains("-"))
                || (seg.count >= 12 && seg.allSatisfy { $0.isHexDigit || $0 == "-" })
            return isID ? "#" : seg.lowercased()
        }
        return host + (segs.isEmpty ? "/" : "/" + segs.joined(separator: "/"))
    }

    // MARK: Procedures → routines

    /// The routine one procedure shows, or nil when its actions hold no step to follow.
    /// `trim`: drop the clicks elsewhere before the work began (`build`'s `place`).
    static func routine(goal: String, at: (start: Date, end: Date), bundleID: String, appName: String, site: String?,
                        actions: [ActionRecord], trim: Bool = true) -> Routine? {
        let (steps, startURL) = build(from: actions, goal: goal, place: trim ? site ?? (bundleID.isEmpty ? nil : bundleID) : nil)
        // One click is not a way of doing something; an app opened is not either.
        guard steps.filter({ $0.kind != .open }).count >= 2 || steps.contains(where: { $0.kind == .type }) else { return nil }
        let slots = Set(steps.compactMap(\.slot).flatMap(tokens))
        let first = steps.first { $0.bundleID != "" }
        return Routine(key: key(bundleID: first?.bundleID ?? bundleID, site: first?.site ?? site, steps: steps),
                       goals: [goal], template: template(goal, slots: slots), bundleID: first?.bundleID ?? bundleID,
                       appName: first?.app ?? appName, site: first?.site ?? site,
                       startURL: (first?.site != nil) ? startURL : nil, steps: steps, count: 1, first: at.start, last: at.end)
    }

    /// The goal with its slot words as "…": "message Haakon Olsen on Slack" → "message … on Slack".
    static func template(_ goal: String, slots: Set<String>) -> String {
        guard !slots.isEmpty else { return goal }
        var out: [String] = []
        for w in goal.split(separator: " ").map(String.init) {
            if tokens(w).contains(where: slots.contains) { if out.last != "…" { out.append("…") } } else { out.append(w) }
        }
        return out.joined(separator: " ")
    }

    /// Identity of a routine: where it starts and its steps up to their slots.
    static func key(bundleID: String, site: String?, steps: [RoutineStep]) -> String {
        let skeleton = steps.map { s in "\(s.kind.rawValue):\(s.role):\(s.fixedLabel):\(s.slot == nil ? "" : "…"):\(s.shortcut ?? ""):\(s.bundleID)" }
        let text = ([site ?? bundleID] + skeleton).joined(separator: "|")
        // FNV-1a: stable across launches (Swift's Hasher is seeded per process).
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: Compound goals

    /// Verbs that start a second instruction ("…on LinkedIn and review Assignment 3 in Canvas").
    static let verbs = "open|review|send|reply|check|add|create|submit|share|message|email|text|go|view|find|search|look|start|make|write|"
        + "upload|download|install|export|copy|paste|update|edit|read|watch|join|schedule|book|buy|call|forward|complete|access|set|fix|"
        + "merge|delete|remove|post|print|invite|ask|tell|draft|compose|save|move|rename|play|listen|navigate|visit|pull|bring|launch"

    /// "send X on LinkedIn and review Y in Canvas" → ["send X on LinkedIn", "review Y in Canvas"]; a
    /// part under three words joins the next ("Access and review Y" stays one).
    static func goalParts(_ goal: String) -> [String] {
        let pattern = #"(?i),?\s+(?:and then|then|and)\s+(?=(?:"# + verbs + #")\b)"#
        let marked = goal.replacingOccurrences(of: pattern, with: "\u{1F}", options: .regularExpression)
        var parts: [String] = []
        var carry = ""
        for raw in marked.split(separator: "\u{1F}").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let p = carry.isEmpty ? raw : carry + " and " + raw
            if p.split(separator: " ").count < 3 { carry = p } else { parts.append(p); carry = "" }
        }
        if !carry.isEmpty {
            if parts.isEmpty { parts.append(carry) } else { parts[parts.count - 1] += " and " + carry }
        }
        return parts.isEmpty ? [goal] : parts
    }

    /// Steps in runs at one place (an app opened right before a place belongs to it).
    static func segments(_ steps: [RoutineStep]) -> [[RoutineStep]] {
        var out: [[RoutineStep]] = []
        var opened: [RoutineStep] = []
        var place: String?
        for s in steps {
            if s.kind == .open { opened.append(s); continue }
            let here = s.site ?? s.bundleID
            if out.isEmpty || here != place { out.append(opened + [s]); place = here } else { out[out.count - 1] += opened + [s] }
            opened = []
        }
        if !opened.isEmpty {
            if out.isEmpty { out.append(opened) } else { out[out.count - 1] += opened }
        }
        return out
    }

    /// A goal that is two instructions done in two places is two routines, each with its part.
    /// nil when the goal is one instruction, or its parts and places do not pair up.
    static func split(_ r: Routine) -> [Routine]? {
        let parts = goalParts(r.goals.first ?? r.template)
        let segs = segments(r.steps)
        guard parts.count > 1, parts.count == segs.count else { return nil }
        return zip(parts, segs).compactMap { goal, steps in
            guard steps.filter({ $0.kind != .open }).count >= 2 || steps.contains(where: { $0.kind == .type }) else { return nil }
            let first = steps.first { !$0.bundleID.isEmpty }
            // Slots are named again from this part of the goal alone.
            let named = slotWords(goal)
            let restepped = steps.map { s -> RoutineStep in
                var s = s
                guard ![.open, .key, .submit].contains(s.kind) else { return s }
                let shared = tokens(s.label).filter { named.contains($0) }
                s.slot = shared.isEmpty ? nil : shared.joined(separator: " ")
                return s
            }
            let slots = Set(restepped.compactMap(\.slot).flatMap(tokens))
            let site = first?.site
            return Routine(key: key(bundleID: first?.bundleID ?? r.bundleID, site: site, steps: restepped), goals: [goal],
                           template: template(goal, slots: slots), bundleID: first?.bundleID ?? r.bundleID, appName: first?.app ?? r.appName,
                           site: site, startURL: site == r.site ? r.startURL : site.map { "https://" + $0 },
                           steps: restepped, count: 1, first: r.first, last: r.last)
        }
    }

    /// Every procedure's routine, the same routine done several times folded into one (newest
    /// example's labels kept, goals collected, counted). `actions` returns a procedure's actions:
    /// the ones it names, else its session's window aligned to its written steps.
    static func mine(_ procedures: [ProcedureRecord], actions: (ProcedureRecord) -> [ActionRecord]) -> [Routine] {
        var byKey: [String: Routine] = [:]
        for p in procedures.sorted(by: { $0.start > $1.start }) {
            let acted = actions(p)
            // Two instructions done in two places: a routine for each. Otherwise one, from its place on.
            let parts = routine(goal: p.goal, at: (p.start, p.end), bundleID: p.bundleID, appName: p.appName, site: p.site,
                                actions: acted, trim: false).flatMap(split)
            let found = parts ?? routine(goal: p.goal, at: (p.start, p.end), bundleID: p.bundleID, appName: p.appName, site: p.site,
                                         actions: acted).map { [$0] } ?? []
            for r in found {
                if var have = byKey[r.key] {
                    have.count += 1
                    have.first = min(have.first, r.first)
                    if have.goals.count < maxGoals, !have.goals.contains(where: { norm($0) == norm(r.goal) }) { have.goals.append(r.goal) }
                    byKey[r.key] = have
                } else {
                    byKey[r.key] = r
                }
            }
        }
        // How many routines share each fixed step: the user's navigation controls, not one item.
        var seen: [String: Int] = [:]
        for r in byKey.values { for k in Set(r.steps.compactMap(stepKey)) { seen[k, default: 0] += 1 } }
        return byKey.values.map { r in
            var r = r
            r.steps = r.steps.map { s in var s = s; s.seen = stepKey(s).flatMap { seen[$0] }; return s }
            return r
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }

    /// A fixed click's identity across routines: where, which role, which label.
    static func stepKey(_ s: RoutineStep) -> String? {
        guard s.kind == .click, s.slot == nil else { return nil }
        return "\(s.site ?? s.bundleID)|\(s.role)|\(norm(s.label))"
    }
}

private extension Routine {
    var goal: String { goals.first ?? template }
}
