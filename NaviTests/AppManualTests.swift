import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// Apps Navi has never seen: the manual read from the app's own menu bar, the playbook the
/// synthesizer writes, and how the user's own use grows both. Pure logic, no AX, no network.
struct AppManualTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func fusion() -> AppManual {
        let cmds: [AppManual.Command] = [
            .init(title: "New Design", path: "File", combo: "cmd+n"),
            .init(title: "Open…", path: "File", combo: "cmd+o"),
            .init(title: "Save", path: "File", combo: "cmd+s"),
            .init(title: "Export…", path: "File", combo: "cmd+shift+e"),
            .init(title: "STL", path: "File › Export", combo: nil),
            .init(title: "STEP", path: "File › Export", combo: nil),
            .init(title: "3D Print…", path: "File", combo: nil),
            .init(title: "Undo", path: "Edit", combo: "cmd+z"),
            .init(title: "Measure", path: "Inspect", combo: "i"),
            .init(title: "Interference", path: "Inspect", combo: nil),
            .init(title: "Section Analysis", path: "Inspect", combo: nil),
            .init(title: "Create Sketch", path: "Sketch", combo: nil),
            .init(title: "Extrude", path: "Create", combo: "e"),
            .init(title: "Fit", path: "View", combo: "f"),
            .init(title: "Minimize", path: "Window", combo: "cmd+m"),
        ]
        return AppManual(bundleID: "com.autodesk.fusion", appName: "Fusion", version: "2.0.1", menus: ["File", "Edit", "Sketch", "Create", "Inspect", "View", "Window", "Help"],
                         commands: cmds, readAt: now, complete: true)
    }

    // MARK: Relevance

    @Test func goalWordsAndSynonymsFindCommands() {
        let m = Self.fusion()
        let export = m.commands(for: "export the bowl as an stl").map(\.full)
        #expect(export.first == "File › Export › STL", "\(export)")
        #expect(export.contains("File › Export…"))
        #expect(!export.contains("Edit › Undo"))
        // "measurement" → measure / inspect; "check" alone names nothing.
        let measure = m.commands(for: "check the measurement of the bracket").map(\.full)
        #expect(measure.first == "Inspect › Measure", "\(measure)")
        #expect(measure.contains("Inspect › Interference") || measure.contains("Inspect › Section Analysis"))
        #expect(m.commands(for: "do the thing").isEmpty)
        // A verb's forms: "exporting" finds Export.
        #expect(m.commands(for: "start exporting it").first?.title == "Export…")
    }

    @Test func theUsersOwnCommandsRankFirst() {
        let m = Self.fusion()
        let plain = m.commands(for: "save my work").map(\.full)
        #expect(plain.first == "File › Save")
        // This user never uses Save; they export every time: their command comes first among the matches.
        let used = ["File › Export…": 12]
        let theirs = m.commands(for: "save my work", used: used).map(\.full)
        #expect(theirs.first == "File › Export…", "\(theirs)")
        #expect(theirs.contains("File › Save"))
    }

    @Test func offerIsCappedAndDeduplicated() {
        var m = Self.fusion()
        m.commands += (0..<40).map { .init(title: "Export Variant \($0)", path: "Tools", combo: nil) }
        m.commands.append(.init(title: "STL", path: "File › Export", combo: nil))   // a duplicate entry
        let out = m.commands(for: "export as stl")
        #expect(out.count == AppManual.offerLimit)
        #expect(Set(out.map(\.full)).count == out.count)
    }

    // MARK: For Jev

    @Test func genericShortcutsGetTheAppsMeaning() {
        let m = Self.fusion()
        let combos = m.keyCombos(base: CUDecide.keyCombos)
        #expect(combos.first { $0.0 == "cmd+n" }?.1 == "File › New Design (Fusion)")
        #expect(combos.first { $0.0 == "cmd+s" }?.1 == "File › Save (Fusion)")
        // A combo the app does not list keeps the generic wording; the playbook's wording wins over the manual's.
        #expect(combos.first { $0.0 == "cmd+t" }?.1 == "New browser tab")
        let notes = AppSkills.skill(bundleID: "com.apple.Notes")!
        let both = AppSkills.keyCombos(for: notes, base: m.keyCombos(base: CUDecide.keyCombos))
        #expect(both.first { $0.0 == "cmd+n" }?.1.contains("Notes") == true)
    }

    @Test func commandsBecomeOffscreenControlsExceptGenericShortcuts() {
        let m = Self.fusion()
        let els = m.offscreenElements(for: "export the part as stl", used: [:], pid: 42)
        let labels = els.map(\.label)
        #expect(labels.contains("File › Export › STL"))
        // "File › Export…" is cmd+shift+e: not a generic combo, so it is offered as a press, with the shortcut as fallback.
        let export = els.first { $0.label == "File › Export…" }
        #expect(export?.menuShortcut == "cmd+shift+e")
        #expect(export?.role == "AXMenuItem" && export?.path == AppManual.menuBarPath && export?.actions == [AppManual.menuCommandAction])
        #expect(export?.pid == 42)
        // "File › Save" is cmd+s, a generic combo: reached as a shortcut, never offered twice.
        let save = m.offscreenElements(for: "save it", used: [:], pid: 1).map(\.label)
        #expect(!save.contains("File › Save"))
        // Merged after the walk's own off-screen controls, ids renumbered, labels not repeated.
        let existing = [AXElement(id: "o1", role: "AXButton", label: "Export…", frame: .zero, actions: ["AXPress"]),
                        AXElement(id: "o2", role: "AXRow", label: "File › Export › STL", frame: .zero, actions: ["AXPress"])]
        let merged = AppManual.merge(existing, commands: els)
        #expect(merged.map(\.id) == (1...merged.count).map { "o\($0)" })
        #expect(merged.filter { $0.label.lowercased() == "file › export › stl" }.count == 1)
        #expect(merged.count == existing.count + els.count - 1)
        // Jev reads a menu command with its menu and shortcut.
        #expect(CUDecide.offscreenCriterion(export!) == "menu item 'File › Export…' (a command in the app's menu bar; shortcut ⇧⌘E)")
        #expect(CUDecide.offscreenCriterion(existing[0]) == "button 'Export…' (not visible)")
        #expect(m.state["menus"] as? [String] == m.menus)
    }

    // MARK: Store

    @Test func manualStoreRoundTripsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-manuals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppManualStore(directory: dir)
        #expect(store.manual(for: "com.autodesk.fusion") == nil)
        store.store(Self.fusion())
        let again = AppManualStore(directory: dir)
        let m = try #require(again.manual(for: "com.autodesk.fusion"))
        #expect(m.commands.count == Self.fusion().commands.count && m.version == "2.0.1" && m.complete)
        again.removeAll()
        #expect(AppManualStore(directory: dir).manual(for: "com.autodesk.fusion") == nil)
    }

    // MARK: The user's own use

    @Test func appUseCountsCommandsControlsAndRoutines() {
        let b = "com.autodesk.fusion"
        func rec(_ kind: ActionRecord.Kind, role: String = "", label: String, shortcut: String? = nil, path: String? = nil, bundle: String = b) -> ActionRecord {
            ActionRecord(timestamp: Self.now, bundleID: bundle, appName: "Fusion", kind: kind, role: role, label: label, shortcut: shortcut, path: path)
        }
        let actions = [rec(.menu, role: "menu item", label: "Export…", shortcut: "cmd+shift+e", path: "File"),
                       rec(.key, label: "Export…", shortcut: "cmd+shift+e", path: "File"),
                       rec(.key, label: "Measure", shortcut: "i", path: "Inspect"),
                       rec(.click, role: "button", label: "Finish Sketch"), rec(.click, role: "button", label: "Finish Sketch"),
                       rec(.type, role: "field", label: "Name"),
                       rec(.click, role: "button", label: "Elsewhere", bundle: "com.other")]
        let step = RoutineStep(kind: .click, app: "Fusion", bundleID: b, role: "button", label: "Finish Sketch")
        let routines = [Routine(key: "r1", goals: ["finish the sketch"], template: "finish the sketch", bundleID: b, appName: "Fusion", steps: [step], count: 2, first: Self.now, last: Self.now),
                        Routine(key: "r2", goals: ["other app"], template: "other app", bundleID: "com.other", appName: "Other", steps: [step], count: 1, first: Self.now, last: Self.now),
                        Routine(key: "r3", goals: ["bad one"], template: "bad one", bundleID: b, appName: "Fusion", steps: [step], count: 1, first: Self.now, last: Self.now, worked: 0, failed: 3)]
        let use = AppUse.build(bundleID: b, actions: actions, routines: routines)
        #expect(use.commands == ["File › Export…": 2, "Inspect › Measure": 1])
        #expect(use.shortcuts == ["cmd+shift+e": "File › Export…", "i": "Inspect › Measure"])
        #expect(use.controls == ["button ‘Finish Sketch’": 2])
        #expect(use.routines.map(\.goal) == ["finish the sketch"])
        #expect(use.routines.first?.steps == [step.human])
        let state = use.state
        #expect((state["commands_this_user_runs"] as? [[String: Any]])?.first?["command"] as? String == "File › Export…")
        #expect(AppUse.build(bundleID: "x", actions: [], routines: []).isEmpty)
        // Folded into a playbook: their shortcuts and routines.
        var skill = AppSkill(name: "Fusion", bundleIDs: [b], howItWorks: ["a"], shortcuts: ["cmd+shift+e": "Export (model's guess)"])
        SkillSynthesizer.apply(use, to: &skill)
        #expect(skill.shortcuts["cmd+shift+e"] == "File › Export… (this user's shortcut)")
        #expect(skill.recipes.count == 1 && skill.recipes[0].goal.hasPrefix("finish the sketch") && skill.recipes[0].keywords == ["finish", "sketch"])
    }

    // MARK: Synthesizer

    @Test func parseKeepsOnlyWhatJevCanUse() throws {
        let json: [String: Any] = [
            "how_it_works": ["The Design workspace has a toolbar of tabs: Solid, Surface, Mesh, Sheet Metal."],
            "shortcuts": [["combo": "Cmd+Shift+E", "does": "Export"], ["combo": "return", "does": "confirm"], ["combo": "not a key", "does": "x"], ["combo": "e", "does": "Extrude"]],
            "recipes": [["goal": "export the design as STL", "keywords": ["Export", "STL", "the"], "steps": ["MENU File › Export…", "SELECT STL in Type", "DONE when the Export dialog closes"]],
                        ["goal": "", "keywords": ["x"], "steps": ["CLICK x"]],
                        ["goal": "no steps", "keywords": ["y"], "steps": []],
                        ["goal": "no keywords given", "keywords": [], "steps": ["CLICK a"]]],
            "done_when": ["the exported file appears in Finder"], "avoid": ["clicking the canvas to select nothing"], "field_hints": [],
            "aliases": ["fusion 360", "Fusion", "notes"], "triggers": ["cad", "the"],
            "deep_links": [["name": "Home", "url": "https://example.com/"], ["name": "bad", "url": "http://x"], ["name": "search", "url": "https://example.com/s?q=x"]],
        ]
        let s = try #require(SkillSynthesizer.parse(json, name: "Fusion", bundleIDs: ["com.autodesk.fusion"], hosts: []))
        #expect(s.shortcuts == ["cmd+shift+e": "Export", "e": "Extrude"])
        #expect(s.recipes.count == 2)
        #expect(s.recipes[0].keywords == ["export", "stl"])
        #expect(s.recipes[1].goal == "no keywords given" && s.recipes[1].keywords == ["given", "keywords", "no"])
        #expect(s.aliases == ["fusion 360"] && s.triggers == ["cad"])
        #expect(s.deepLinks == ["home": "https://example.com/"])
        #expect(SkillSynthesizer.parse(["how_it_works": []], name: "X", bundleIDs: ["x"], hosts: []) == nil)
    }

    @Test func sitesGetTheirRegistrableHostAndName() {
        #expect(SkillSynthesizer.hosts(for: "https://olinbaja.onshape.com/documents/abc") == ["onshape.com", "olinbaja.onshape.com"])
        #expect(SkillSynthesizer.hosts(for: "https://www.tinkercad.com/dashboard") == ["tinkercad.com"])
        #expect(SkillSynthesizer.hosts(for: "https://app.example.co.uk/x") == ["example.co.uk", "app.example.co.uk"])
        #expect(SkillSynthesizer.hosts(for: "https://www.google.com/search?q=x").isEmpty)
        #expect(SkillSynthesizer.hosts(for: nil).isEmpty)
        #expect(SkillSynthesizer.siteName(for: ["onshape.com"], title: nil) == "Onshape")
        #expect(GeneratedSkillStore.key(bundleID: "com.google.Chrome", host: "onshape.com") == "host:onshape.com")
        #expect(GeneratedSkillStore.key(bundleID: "com.autodesk.fusion", host: nil) == "com.autodesk.fusion")
        #expect(GeneratedSkillStore.key(bundleID: "com.google.Chrome", host: nil) == nil)
    }

    @Test func generatedSkillsJoinTheLibraryAndLearn() throws {
        let b = "com.test.unfamiliar-\(UUID().uuidString.prefix(8))"
        let name = "Unfamiliarapp\(UUID().uuidString.prefix(4))"
        let now = Self.now
        let stored = StoredSkill(key: b, name: name, bundleIDs: [b], hosts: [], howItWorks: ["It has a canvas."],
                                 shortcuts: ["cmd+e": "Export"],
                                 recipes: [.init(goal: "export the model as stl", keywords: ["export", "stl"], steps: ["MENU File › Export", "DONE when saved"])],
                                 doneWhen: [], avoid: [], fieldHints: [], deepLinks: [:], aliases: [name.lowercased() + "x"], triggers: [],
                                 model: "m", appVersion: "1", createdAt: now, updatedAt: now)
        GeneratedSkillStore.shared.upsert(stored)
        defer { GeneratedSkillStore.shared.update(key: b) { _ in }; GeneratedSkillStore.shared.removeAll() }
        #expect(AppSkills.skill(bundleID: b)?.name == name)
        #expect(AppSkills.all.contains { $0.name == name })
        #expect(AppSkills.mentioned(in: "open \(name.lowercased())x and export")?.name == name)
        #expect(AppSkills.playbook(for: AppSkills.skill(bundleID: b)!, goal: "export it as stl")["recipes"] != nil)
        // The library keeps winning: Notes is Notes.
        #expect(AppSkills.skill(bundleID: "com.apple.Notes")?.name == "Notes")

        // A run that achieved the goal with no matching recipe becomes a learned recipe; a matching one counts.
        SkillSynthesizer.learn(bundleID: b, url: nil, goal: "measure the width", actions: ["Press ‘Inspect › Measure’", "Click ‘Edge’"], achieved: true, lastAction: nil)
        var s = try #require(GeneratedSkillStore.shared.stored(key: b))
        #expect(s.recipes.count == 2 && s.recipes[1].source == "learned" && s.recipes[1].worked == 1 && s.recipes[1].keywords == ["measure", "width"])
        SkillSynthesizer.learn(bundleID: b, url: nil, goal: "export as stl", actions: ["Click ‘Canvas’"], achieved: false, lastAction: "Click ‘Canvas’")
        s = try #require(GeneratedSkillStore.shared.stored(key: b))
        #expect(s.recipes[0].failed == 1)
        #expect(s.avoid.first?.hasPrefix("‘Click ‘Canvas’’ did not get to: export as stl") == true)
        // Two failures and no success: the recipe is no longer offered.
        SkillSynthesizer.learn(bundleID: b, url: nil, goal: "export as stl", actions: [], achieved: false, lastAction: nil)
        #expect(AppSkills.skill(bundleID: b)?.recipes.map(\.goal) == ["measure the width"])
        #expect(SkillSynthesizer.goalKey(skillKey: b, goal: "Export the STL please") == SkillSynthesizer.goalKey(skillKey: b, goal: "export stl"))
    }

    @Test func appsATaskNamesAmongRunningOnes() {
        // No live apps under tests: the name rule alone.
        let lower = " measure it in fusion then save "
        #expect(AppKnowledge.apps(for: lower, front: nil, running: []).isEmpty)
        #expect(AppManual.terms(of: "export the bowl as an stl").keys.sorted() == ["bowl", "export", "stl"])
        #expect(AppManual.terms(of: "export it")["export"]?.contains("save as") == true)
    }
}
