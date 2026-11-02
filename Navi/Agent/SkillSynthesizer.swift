import AppKit
import Foundation

// Playbooks Navi writes for itself. `AppSkillLibrary` is the hand-written half of what Jev
// knows about apps; this is the half that grows: the first time a run reaches an app or site
// with no skill, Claude writes one of the same shape from what the app itself says (its
// manual — `AppManual` —, one snapshot's control labels, the user's own use of it — `AppUse`)
// and what it knows of the app, and the file joins the library (`GeneratedSkillStore`). Goals
// no recipe covers get one of their own (`recipe(for:)`, cheap, cached by goal words). Runs
// then refine the file: what worked becomes a recipe, what went wrong an `avoid` line.
//
// Privacy: packets carry labels, menu titles, counts and the user's own routine step lines —
// never typed text, field values, screen text or OCR. Files live in Application Support and go
// with "Delete everything Navi has stored".

/// `AppSkill` on disk, plus where it came from.
struct StoredSkill: Codable, Equatable, Sendable {
    struct Recipe: Codable, Equatable, Sendable {
        var goal: String
        var keywords: [String]
        var steps: [String]
        /// "generated" (with the skill), "goal" (asked for one goal), "learned" (from a run).
        var source: String = "generated"
        var worked: Int = 0
        var failed: Int = 0
    }

    var key: String
    var name: String
    var bundleIDs: [String]
    var hosts: [String]
    var howItWorks: [String]
    var shortcuts: [String: String]
    var recipes: [Recipe]
    var doneWhen: [String]
    var avoid: [String]
    var fieldHints: [String]
    var deepLinks: [String: String]
    var aliases: [String]
    var triggers: [String]
    var model: String
    var appVersion: String
    var createdAt: Date
    var updatedAt: Date

    var skill: AppSkill {
        AppSkill(name: name, bundleIDs: bundleIDs, hosts: hosts, howItWorks: howItWorks, shortcuts: shortcuts,
                 recipes: recipes.filter { !($0.failed >= 2 && $0.failed > $0.worked) }.map { .init(goal: $0.goal, keywords: $0.keywords, steps: $0.steps) },
                 doneWhen: doneWhen, avoid: avoid, fieldHints: fieldHints, deepLinks: deepLinks, aliases: aliases, triggers: triggers)
    }
}

/// The generated skills, in memory and under `Application Support/Navi/skills/`.
final class GeneratedSkillStore: @unchecked Sendable {
    static let shared = GeneratedSkillStore()

    private let lock = NSLock()
    private var stored: [String: StoredSkill] = [:]
    private var loaded = false
    private let directory: URL?
    /// Bumped on every change: `AppSkills` rebuilds what it derives from the list.
    private(set) var version = 0
    private(set) var mentionPatterns: [AppSkills.MentionPattern] = []

    /// `directory: nil` keeps everything in memory (tests).
    init(directory: URL? = GeneratedSkillStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        TestHost.isActive ? nil : NaviSettings.dataDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    static let maxSkills = 400

    private var skillsCache: (version: Int, skills: [AppSkill])?

    /// Every generated skill, oldest first (a stable order keeps Jev's state deterministic).
    var skills: [AppSkill] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if let c = skillsCache, c.version == version { return c.skills }
        let list = stored.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.key < $1.key }.map(\.skill)
        skillsCache = (version, list)
        return list
    }

    func stored(key: String) -> StoredSkill? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return stored[key]
    }

    /// The key a skill is filed under: the bundle id, or "host:" + the site.
    static func key(bundleID: String?, host: String?) -> String? {
        if let b = bundleID, !b.isEmpty, !AXSnapshotter.isBrowser(b) { return b }
        if let h = host, !h.isEmpty { return "host:" + h }
        return nil
    }

    func upsert(_ s: StoredSkill) {
        lock.lock()
        loadIfNeeded()
        stored[s.key] = s
        if stored.count > Self.maxSkills, let oldest = stored.values.min(by: { $0.updatedAt < $1.updatedAt }) { stored.removeValue(forKey: oldest.key) }
        version += 1
        mentionPatterns = AppSkills.mentionPatterns(for: stored.values.map(\.skill))
        lock.unlock()
        save(s)
    }

    /// Changes one stored skill in place (a recipe added, a count bumped). No-op when missing.
    func update(key: String, _ change: (inout StoredSkill) -> Void) {
        lock.lock()
        loadIfNeeded()
        guard var s = stored[key] else { lock.unlock(); return }
        change(&s)
        s.updatedAt = Date()
        stored[key] = s
        version += 1
        lock.unlock()
        save(s)
    }

    func removeAll() {
        lock.lock(); stored = [:]; loaded = true; version += 1; mentionPatterns = []; lock.unlock()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Disk

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let s = try? dec.decode(StoredSkill.self, from: data) { stored[s.key] = s }
        }
        mentionPatterns = AppSkills.mentionPatterns(for: stored.values.map(\.skill))
    }

    private func fileURL(_ key: String) -> URL? {
        let safe = key.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
        return directory?.appendingPathComponent(safe + ".json")
    }

    private func save(_ s: StoredSkill) {
        guard let directory, let url = fileURL(s.key) else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch {
            Log.agent.error("GeneratedSkillStore: could not save \(s.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum SkillSynthesizer {
    /// The cheap model for one goal's recipe; the skill itself uses the agent model (once per app).
    static let recipeModel = "claude-haiku-4-5"
    static let maxRecipes = 10
    static let maxGoalRecipes = 30
    static let maxScreenLabels = 80

    // MARK: Packet and schema (pure)

    static let system = """
    You write Navi's playbook for an app it has never driven. Navi drives apps one action at a time with a small \
    classifier (Jev) that sees only structured state: the accessibility tree (controls with their labels, static \
    text), the app's menu-bar commands, this playbook, and what the user did before. Jev has no knowledge of its own, \
    so the playbook must say what a competent user knows: where things are and how the UI behaves (how_it_works), \
    the keyboard shortcuts you are sure of (shortcuts), recipes for the goals people ask for in this app (recipes: the \
    words users say as keywords; steps in Navi's vocabulary — KEY <combo>, CLICK <exact label>, MENU <menu › item>, \
    TYPE_TEXT into <field>, SELECT <value> in <pop-up>, RIGHT_CLICK <item>, DONE when <visible evidence>), the visible \
    evidence that the usual goals are complete (done_when), and wrong moves (avoid). Prefer the labels the manual and \
    the screen give you; a shortcut not in the manual only when it is standard for this app. Combos are spelled \
    "cmd+shift+e", "return", "escape". When the state shows how this user works here, prefer their way: their commands, \
    shortcuts and routines. Never include personal data, file names or typed text. Keep it compact: 4–8 facts, at most \
    10 recipes of 2–8 steps, 2–6 done_when and avoid lines.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["how_it_works", "shortcuts", "recipes", "done_when", "avoid", "field_hints", "aliases", "triggers", "deep_links"],
        "properties": [
            "how_it_works": ["type": "array", "items": ["type": "string"]],
            "shortcuts": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["combo", "does"],
                                                     "properties": ["combo": ["type": "string"], "does": ["type": "string"]]]],
            "recipes": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["goal", "keywords", "steps"],
                                                   "properties": ["goal": ["type": "string"], "keywords": ["type": "array", "items": ["type": "string"]],
                                                                  "steps": ["type": "array", "items": ["type": "string"]]]]],
            "done_when": ["type": "array", "items": ["type": "string"]],
            "avoid": ["type": "array", "items": ["type": "string"]],
            "field_hints": ["type": "array", "items": ["type": "string"]],
            "aliases": ["type": "array", "items": ["type": "string"]],
            "triggers": ["type": "array", "items": ["type": "string"]],
            "deep_links": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["name", "url"],
                                                      "properties": ["name": ["type": "string"], "url": ["type": "string"]]]],
        ],
    ]

    static let recipeSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["possible", "goal", "keywords", "steps", "done_when"],
        "properties": [
            "possible": ["type": "boolean"],
            "goal": ["type": "string"],
            "keywords": ["type": "array", "items": ["type": "string"]],
            "steps": ["type": "array", "items": ["type": "string"]],
            "done_when": ["type": "string"],
        ],
    ]

    static let recipeSystem = """
    You write one recipe for Navi's playbook: how a competent user does this one goal in this app, as 2–8 steps in \
    Navi's vocabulary (KEY <combo>, CLICK <exact label>, MENU <menu › item>, TYPE_TEXT into <field>, SELECT <value> \
    in <pop-up>, RIGHT_CLICK <item>, DONE when <visible evidence>). Use the labels the manual and the screen give; prefer \
    the way this user does it when the state shows one. `possible` is false when the app cannot do this goal. Keywords \
    are the lower-case words a user would say for this goal. Never include personal data or typed text.
    """

    /// Everything the writer gets about the app. `screen`: control labels of one snapshot.
    static func packet(appName: String, bundleID: String?, hosts: [String], manual: AppManual?, screen: [String], use: AppUse?,
                       windowTitle: String? = nil) -> [String: Any] {
        var p: [String: Any] = ["app": appName]
        if let bundleID { p["bundle_id"] = bundleID }
        if !hosts.isEmpty { p["hosts"] = hosts; p["kind"] = "web app in a browser" } else { p["kind"] = "native macOS app" }
        if let manual {
            var m: [String: Any] = ["menus": manual.menus]
            m["commands"] = manual.commands.prefix(400).map { c in
                var d: [String: Any] = ["command": c.full]
                if let k = c.combo { d["shortcut"] = k }
                return d
            }
            p["manual"] = m
        }
        if !screen.isEmpty { p["controls_on_screen_now"] = Array(screen.prefix(maxScreenLabels)) }
        if let use, !use.isEmpty { p["how_this_user_works_here"] = use.state }
        if let t = windowTitle, !t.isEmpty, use == nil { p["window"] = String(t.prefix(80)) }
        return p
    }

    /// The model's JSON as an `AppSkill`: combos must parse, keywords are lower-cased, links are
    /// https, lists are capped. nil when nothing usable came back.
    static func parse(_ json: [String: Any], name: String, bundleIDs: [String], hosts: [String]) -> AppSkill? {
        func strings(_ k: String, max: Int) -> [String] {
            ((json[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.prefix(max).map { String($0.prefix(300)) }
        }
        let how = strings("how_it_works", max: 10)
        guard !how.isEmpty else { return nil }
        var shortcuts: [String: String] = [:]
        for s in (json["shortcuts"] as? [[String: Any]]) ?? [] {
            guard let combo = (s["combo"] as? String)?.lowercased().replacingOccurrences(of: " ", with: ""),
                  let does = (s["does"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !does.isEmpty, (try? KeyCombo.parse(combo)) != nil, !CUDecide.keysThatAreKinds.contains(combo) else { continue }
            shortcuts[combo] = String(does.prefix(120))
        }
        let recipes = parseRecipes((json["recipes"] as? [[String: Any]]) ?? []).prefix(maxRecipes).map { $0 }
        var links: [String: String] = [:]
        for l in (json["deep_links"] as? [[String: Any]]) ?? [] {
            guard let n = (l["name"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty,
                  let u = l["url"] as? String, u.hasPrefix("https://"), URL(string: u) != nil else { continue }
            if n == "search" && !(u.hasSuffix("=") || u.hasSuffix("/")) { continue }
            links[n] = u
        }
        let lower = { (xs: [String]) in xs.map { $0.lowercased() }.filter { !$0.isEmpty } }
        // The app's own name is never an alias (it is matched already) and library names are not stolen.
        let taken = Set(AppSkills.library.flatMap { [$0.name.lowercased()] + $0.aliases })
        let aliases = lower(strings("aliases", max: 6)).filter { $0 != name.lowercased() && !taken.contains($0) && $0.count >= 3 }
        let triggers = lower(strings("triggers", max: 8)).filter { !taken.contains($0) && $0.count >= 3 && !AppManual.stopWords.contains($0) }
        return AppSkill(name: name, bundleIDs: bundleIDs, hosts: hosts, howItWorks: how, shortcuts: shortcuts, recipes: recipes,
                        doneWhen: strings("done_when", max: 6), avoid: strings("avoid", max: 8), fieldHints: strings("field_hints", max: 6),
                        deepLinks: links, aliases: aliases, triggers: triggers)
    }

    static func parseRecipes(_ raw: [[String: Any]]) -> [AppSkill.Recipe] {
        raw.compactMap { r in
            guard let goal = (r["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else { return nil }
            let steps = ((r["steps"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.prefix(10).map { String($0.prefix(200)) }
            var keywords = ((r["keywords"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !AppManual.stopWords.contains($0) }
            if keywords.isEmpty { keywords = Array(AgentExperience.words(goal)).sorted() }
            guard !steps.isEmpty, !keywords.isEmpty else { return nil }
            return AppSkill.Recipe(goal: String(goal.prefix(120)), keywords: Array(keywords.prefix(12)), steps: steps)
        }
    }

    /// Host entries for a site: the host itself and its registrable domain, so the user's own
    /// instance (olinbaja.onshape.com) and the plain site both match.
    static func hosts(for url: String?) -> [String] {
        guard let url, let h = URL(string: url)?.host?.lowercased() else { return [] }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2, !noSkillHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return [] }
        let second: Set<String> = ["co", "com", "org", "net", "ac", "edu", "gov"]
        let n = parts.count >= 3 && second.contains(parts[parts.count - 2]) && parts.last!.count == 2 ? 3 : 2
        let registrable = parts.suffix(n).joined(separator: ".")
        return registrable == host ? [host] : [registrable, host]
    }

    /// Sites that are nobody's app: search engines, blank pages, Navi's own.
    static let noSkillHosts: Set<String> = ["google.com", "bing.com", "duckduckgo.com", "yahoo.com", "startpage.com", "ecosia.org",
                                             "brave.com", "kagi.com", "localhost", "newtab", "about:blank"]

    /// The skill's name for a site: "Onshape" from onshape.com.
    static func siteName(for hosts: [String], title: String?) -> String {
        if let h = hosts.first, let label = h.split(separator: ".").first {
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        return title ?? "Site"
    }

    // MARK: Synthesis

    nonisolated(unsafe) private static var registered: (model: String, claude: ClaudeClient)?

    /// The client and model later calls without one use (`noteSite`); set per run by `ComputerAgent`.
    static func register(model: String, claude: ClaudeClient) {
        lock.lock(); registered = (model, claude); lock.unlock()
    }

    /// A site the browser runner worked on (its final page): a playbook for it when it has none,
    /// ready for the next run there. Labels are not known here (the runner reads the DOM).
    static func noteSite(url: String?, title: String?) {
        lock.lock(); let r = registered; lock.unlock()
        guard let r, let url, url.hasPrefix("http") else { return }
        let browser = NativeBrowser.defaultBrowserBundleID() ?? "com.google.Chrome"
        ensure(bundleID: browser, appName: nil, url: url, pid: nil, labels: [], windowTitle: title, model: r.model, claude: r.claude)
    }

    nonisolated(unsafe) private static var inFlight: Set<String> = []
    nonisolated(unsafe) private static var goalInFlight: Set<String> = []
    private static let lock = NSLock()

    /// Writes and stores the skill for an app or site with none, once; later calls while it is
    /// being written, or once it exists, return at once. `labels`: control labels on screen now.
    static func ensure(bundleID: String?, appName: String?, url: String?, pid: pid_t?, labels: [String], windowTitle: String?,
                       model: String, claude: ClaudeClient) {
        let hosts = (bundleID.map(AXSnapshotter.isBrowser) ?? true) ? hosts(for: url) : []
        guard let key = GeneratedSkillStore.key(bundleID: bundleID, host: hosts.first) else { return }
        // A site in a browser is judged by its own skill, not the browser's.
        let existing = hosts.isEmpty ? AppSkills.skill(bundleID: bundleID) : AppSkills.skill(url: url)
        guard claude.isConfigured, existing == nil, GeneratedSkillStore.shared.stored(key: key) == nil else { return }
        lock.lock()
        let busy = !inFlight.insert(key).inserted
        lock.unlock()
        if busy { return }
        let native = !hosts.isEmpty ? nil : bundleID
        let name = native.map { appName ?? AppSkills.displayName(bundleID: $0) } ?? siteName(for: hosts, title: windowTitle)
        Task.detached(priority: .userInitiated) {
            defer { lock.lock(); inFlight.remove(key); lock.unlock() }
            var manual: AppManual? = nil
            if let native, let pid, pid > 0 { manual = await AppManualStore.shared.ensure(pid: pid, bundleID: native, appName: name) }
            let use = native.map { AppUse.live(bundleID: $0) }
            let packet = packet(appName: name, bundleID: native, hosts: hosts, manual: manual, screen: labels,
                                use: use?.isEmpty == false ? use : nil, windowTitle: windowTitle)
            let started = Date()
            do {
                let json = try await claude.structured(model: model, system: system, packet: packet, schema: schema, maxTokens: 4000, effort: "medium")
                guard var skill = parse(json, name: name, bundleIDs: native.map { [$0] } ?? [], hosts: hosts) else {
                    Log.agent.error("SkillSynthesizer: nothing usable for \(name, privacy: .public)")
                    return
                }
                if let use { apply(use, to: &skill) }
                let now = Date()
                let stored = StoredSkill(key: key, name: skill.name, bundleIDs: skill.bundleIDs, hosts: skill.hosts, howItWorks: skill.howItWorks,
                                         shortcuts: skill.shortcuts,
                                         recipes: skill.recipes.map { .init(goal: $0.goal, keywords: $0.keywords, steps: $0.steps) },
                                         doneWhen: skill.doneWhen, avoid: skill.avoid, fieldHints: skill.fieldHints, deepLinks: skill.deepLinks,
                                         aliases: skill.aliases, triggers: skill.triggers, model: model, appVersion: manual?.version ?? "",
                                         createdAt: now, updatedAt: now)
                GeneratedSkillStore.shared.upsert(stored)
                Log.agent.info("SkillSynthesizer: wrote a playbook for \(name, privacy: .public) (\(skill.recipes.count) recipes, \(skill.shortcuts.count) shortcuts) in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) s")
            } catch {
                Log.agent.error("SkillSynthesizer: \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The user's own use folded into a skill: the shortcuts they press (with the command each
    /// runs here) win over the model's; their routines become recipes (`learned`).
    static func apply(_ use: AppUse, to skill: inout AppSkill) {
        for (combo, command) in use.shortcuts where (try? KeyCombo.parse(combo)) != nil && !CUDecide.keysThatAreKinds.contains(combo) {
            skill.shortcuts[combo] = command + " (this user's shortcut)"
        }
        for r in use.routines.prefix(4) where !r.steps.isEmpty {
            let keywords = Array(AgentExperience.words(r.goal)).sorted()
            guard !keywords.isEmpty, !skill.recipes.contains(where: { $0.goal.lowercased() == r.goal.lowercased() }) else { continue }
            skill.recipes.append(.init(goal: "\(r.goal) (how this user did it)", keywords: keywords, steps: Array(r.steps.prefix(10))))
        }
    }

    // MARK: One goal's recipe

    /// Cache key for a goal in a skill: the skill's key and the goal's content words.
    static func goalKey(skillKey: String, goal: String) -> String {
        skillKey + "|" + AgentExperience.words(goal).sorted().joined(separator: " ")
    }

    /// A generated skill with no recipe for this goal gets one written for it (Haiku, ~2 s),
    /// stored in the skill (`source: "goal"`) so `AppSkills.recipes(for:goal:)` offers it on the
    /// next step and on every later run. Once per goal; nothing for library skills.
    static func ensureRecipe(for goal: String, bundleID: String?, url: String?, manual: AppManual?, labels: [String], claude: ClaudeClient) {
        let hosts = (bundleID.map(AXSnapshotter.isBrowser) ?? true) ? hosts(for: url) : []
        guard let key = GeneratedSkillStore.key(bundleID: bundleID, host: hosts.first), let stored = GeneratedSkillStore.shared.stored(key: key),
              claude.isConfigured, !AppSkills.recipes(for: stored.skill, goal: goal).contains(where: { !$0.steps.isEmpty }) else { return }
        let words = AgentExperience.words(goal)
        guard words.count >= 1, stored.recipes.filter({ $0.source == "goal" }).count < maxGoalRecipes else { return }
        let gk = goalKey(skillKey: key, goal: goal)
        lock.lock()
        let busy = !goalInFlight.insert(gk).inserted
        lock.unlock()
        if busy { return }
        Task.detached(priority: .userInitiated) {
            defer { lock.lock(); goalInFlight.remove(gk); lock.unlock() }
            var p = packet(appName: stored.name, bundleID: stored.bundleIDs.first, hosts: stored.hosts, manual: manual, screen: labels,
                           use: stored.bundleIDs.first.map { AppUse.live(bundleID: $0) }.flatMap { $0.isEmpty ? nil : $0 })
            p["goal"] = goal
            p["playbook"] = ["how_it_works": stored.howItWorks, "shortcuts": stored.shortcuts, "avoid": stored.avoid]
            do {
                let json = try await claude.structured(model: recipeModel, system: recipeSystem, packet: p, schema: recipeSchema, maxTokens: 800)
                guard (json["possible"] as? Bool) != false, var recipe = parseRecipes([json]).first else { return }
                if let done = (json["done_when"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !done.isEmpty,
                   !recipe.steps.contains(where: { $0.uppercased().hasPrefix("DONE") }) {
                    recipe.steps.append("DONE when " + done)
                }
                // The goal's own words are keywords, so this very goal matches next time.
                recipe.keywords = Array(Set(recipe.keywords).union(words)).sorted()
                GeneratedSkillStore.shared.update(key: key) { s in
                    s.recipes.append(.init(goal: recipe.goal, keywords: recipe.keywords, steps: recipe.steps, source: "goal"))
                }
                Log.agent.info("SkillSynthesizer: recipe for ‘\(goal.prefix(60), privacy: .public)’ in \(stored.name, privacy: .public): \(recipe.steps.count) steps")
            } catch {
                Log.agent.error("SkillSynthesizer: recipe for \(stored.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Before a browser run: when the start page's site has a generated playbook with no recipe for this
    /// goal, one is asked for and waited on briefly (`recipeWait`), so this run — not the next — starts
    /// with it. Nothing happens for library sites or sites with no playbook yet.
    static let recipeWait: TimeInterval = 2.5
    static func recipeBeforeRun(task: String, url: String?) async {
        lock.lock(); let r = registered; lock.unlock()
        guard let r, let url, url.hasPrefix("http") else { return }
        let hosts = hosts(for: url)
        guard let key = GeneratedSkillStore.key(bundleID: "com.google.Chrome", host: hosts.first), let stored = GeneratedSkillStore.shared.stored(key: key),
              AppSkills.recipes(for: stored.skill, goal: task).isEmpty else { return }
        ensureRecipe(for: task, bundleID: "com.google.Chrome", url: url, manual: nil, labels: [], claude: r.claude)
        let deadline = Date().addingTimeInterval(recipeWait)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let now = GeneratedSkillStore.shared.stored(key: key), !AppSkills.recipes(for: now.skill, goal: task).isEmpty { return }
        }
    }

    // MARK: Learning from runs

    /// A run in a generated-skill app ended: `achieved` ⇒ its actions become a `learned` recipe
    /// for this goal (or bump the one that matched); not achieved ⇒ the recipe that matched
    /// counts a failure and the last action goes to `avoid` when it was the screen's dead end.
    static func learn(bundleID: String?, url: String?, goal: String, actions: [String], achieved: Bool, lastAction: String?) {
        let hosts = (bundleID.map(AXSnapshotter.isBrowser) ?? true) ? hosts(for: url) : []
        guard let key = GeneratedSkillStore.key(bundleID: bundleID, host: hosts.first), GeneratedSkillStore.shared.stored(key: key) != nil else { return }
        let words = Array(AgentExperience.words(goal)).sorted()
        guard !words.isEmpty else { return }
        GeneratedSkillStore.shared.update(key: key) { s in
            let matched = AppSkills.recipes(for: s.skill, goal: goal).map(\.goal)
            if achieved {
                if let i = s.recipes.firstIndex(where: { matched.contains($0.goal) }) {
                    s.recipes[i].worked += 1
                } else if !actions.isEmpty, actions.count <= 12 {
                    s.recipes.append(.init(goal: String(goal.prefix(120)), keywords: words, steps: actions.map { String($0.prefix(120)) }, source: "learned", worked: 1))
                }
            } else {
                for i in s.recipes.indices where matched.contains(s.recipes[i].goal) && s.recipes[i].source != "learned" { s.recipes[i].failed += 1 }
                if let last = lastAction, !last.isEmpty, s.avoid.count < 12 {
                    let line = "‘\(String(last.prefix(80)))’ did not get to: \(String(goal.prefix(80)))"
                    if !s.avoid.contains(line) { s.avoid.append(line) }
                }
            }
        }
    }
}

// MARK: - While typing

/// What a run should know about an app before it starts, prepared while the user types
/// (`ComputerAgent.prepare`): the manual of the app in front and of a running app the task
/// names, a playbook for one that has none, and a recipe for this goal in a generated one.
/// Cheap when everything is cached; the same task is not looked at twice within a few seconds.
enum AppKnowledge {
    nonisolated(unsafe) private static var last: (task: String, at: Date)?
    private static let lock = NSLock()
    static let throttle: TimeInterval = 3

    /// Running apps the task names ("measure it in fusion"): by name, whole word, names of
    /// four letters or more that are not ordinary words. The app in front comes first.
    static func apps(for task: String, front: NSRunningApplication?, running: [NSRunningApplication]) -> [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        if let front { out.append(front) }
        let lower = " " + task.lowercased().replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression) + " "
        for a in running where a.activationPolicy == .regular {
            guard let n = a.localizedName?.lowercased(), n.count >= 4, !AppSkills.commonWordNames.contains(n), lower.contains(" " + n + " "),
                  !out.contains(where: { $0.processIdentifier == a.processIdentifier }) else { continue }
            out.append(a)
        }
        return Array(out.prefix(3))
    }

    @MainActor
    static func prepare(task: String, model: String, claude: ClaudeClient) {
        guard !TestHost.isActive, claude.isConfigured else { return }
        let now = Date()
        lock.lock()
        if let l = last, l.task == task, now.timeIntervalSince(l.at) < throttle { lock.unlock(); return }
        last = (task, now)
        lock.unlock()
        let own = Bundle.main.bundleIdentifier
        for a in apps(for: task, front: UserFront.app(), running: NSWorkspace.shared.runningApplications) {
            let pid = a.processIdentifier, name = a.localizedName
            guard let b = a.bundleIdentifier, b != own, !AXSnapshotter.isBrowser(b), pid > 0 else { continue }
            Task.detached(priority: .utility) {
                let manual = await AppManualStore.shared.ensure(pid: pid, bundleID: b, appName: name)
                if AppSkills.skill(bundleID: b) == nil {
                    SkillSynthesizer.ensure(bundleID: b, appName: name, url: nil, pid: pid, labels: [], windowTitle: nil, model: model, claude: claude)
                } else {
                    SkillSynthesizer.ensureRecipe(for: task, bundleID: b, url: nil, manual: manual, labels: [], claude: claude)
                }
            }
        }
    }
}
