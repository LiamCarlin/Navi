import Testing
import Foundation
@testable import Navi

// Everything here runs on temp directories — never on the tester's real memory, vault or logs.

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("navi-privacy-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func age(_ url: URL, days: Double, now: Date = Date()) throws {
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
}

private func frame(_ ts: Date, text: String, thumb: String? = nil) -> FrameRecord {
    FrameRecord(timestamp: ts, bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs", url: "https://example.com",
                ocrText: text, thumbPath: thumb, phash: 0, activity: "browsing", importance: 2, isNewContext: false)
}

private func session(_ start: Date, title: String) -> SessionRecord {
    SessionRecord(start: start, end: start.addingTimeInterval(600), bundleID: "com.apple.Safari", appName: "Safari",
                  url: nil, title: title, summary: "Worked on \(title).", topics: ["Budget"],
                  entities: [EntityRef(name: "Ada Lovelace", type: "person")])
}

private func digest(_ title: String) -> DigestResult {
    DigestResult(title: title, summary: "Worked on \(title).", topics: ["Budget"],
                 entities: [EntityRef(name: "Ada Lovelace", type: "person")], keyFacts: [], links: [])
}

// MARK: - Retention

struct RetentionTests {
    /// Old frames, sessions, thumbnails and the journal notes Navi wrote go; the user's own notes,
    /// newer notes and hubs that still have something in them stay.
    @Test func retentionPurgesStoreAndNaviNotesOnly() throws {
        let dir = tempDir("retention")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vaultRoot = dir.appendingPathComponent("vault", isDirectory: true)
        let store = try MemoryStore(directory: dir.appendingPathComponent("data"))
        let vault = VaultWriter(root: vaultRoot)
        let now = Date()
        let oldStart = now.addingTimeInterval(-40 * 86_400)
        let newStart = now.addingTimeInterval(-2 * 86_400)

        // An old session with a screenshot, a recent one sharing the same hubs.
        let thumb = dir.appendingPathComponent("data/frames/old.jpg")
        try FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumb)
        let oldFrame = frame(oldStart, text: "old budget numbers", thumb: thumb.path)
        try store.insertFrame(oldFrame)
        try store.insertFrame(frame(newStart, text: "new budget numbers"))
        var oldSession = session(oldStart, title: "Old budget")
        oldSession.id = try store.insertSession(oldSession)
        let oldNote = try vault.write(session: oldSession, digest: digest("Old budget"), frames: [oldFrame], keepScreenshots: true)
        try store.updateSessionNotePath(sessionID: oldSession.id, notePath: oldNote)
        var newSession = session(newStart, title: "New budget")
        newSession.id = try store.insertSession(newSession)
        let newNote = try vault.write(session: newSession, digest: digest("New budget"), frames: [], keepScreenshots: false)
        try store.updateSessionNotePath(sessionID: newSession.id, notePath: newNote)

        // Something only Navi links to, and the user's own notes in Navi's folders.
        let onlyOld = vaultRoot.appendingPathComponent("Topics/Solo.md")
        try write("---\ntype: topic\ntags: [navi/topic]\n---\n\n# Solo\n\n## Seen in\n- x [[\(oldNote.dropLast(3))|Old budget]]\n", onlyOld)
        let userNote = vaultRoot.appendingPathComponent("Sessions/My own thoughts.md")
        try write("# My own thoughts\n\nNot Navi's.\n", userNote)
        let userHub = vaultRoot.appendingPathComponent("Topics/Mine.md")
        try write("---\ntags: [navi/topic]\n---\n\n# Mine\n\nI wrote this paragraph.\n\n## Seen in\n- x [[\(oldNote.dropLast(3))|Old budget]]\n", userHub)

        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let result = try store.prune(before: cutoff)
        #expect(result.frames == 1)
        #expect(result.sessions == 1)
        #expect(result.sessionNotePaths == [oldNote])
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        #expect(try store.search(query: "old", limit: 5).isEmpty)
        #expect(try store.frameCount() == 1)

        let report = VaultCleanup(root: vaultRoot).prune(sessionNotePaths: result.sessionNotePaths, before: cutoff)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: vaultRoot.appendingPathComponent(oldNote).path))
        #expect(fm.fileExists(atPath: vaultRoot.appendingPathComponent(newNote).path))
        #expect(report.attachmentsDeleted == 1)
        #expect(!fm.fileExists(atPath: onlyOld.path))                 // nothing left in it
        #expect(fm.fileExists(atPath: userNote.path))                 // not Navi's
        #expect(fm.fileExists(atPath: userHub.path))                  // has the user's text
        #expect(!(try String(contentsOf: userHub, encoding: .utf8)).contains("Old budget"))
        // The shared hubs keep the recent session's line only.
        let hub = try String(contentsOf: vaultRoot.appendingPathComponent("Topics/Budget.md"), encoding: .utf8)
        #expect(hub.contains("New budget") && !hub.contains("Old budget"))
        // The old day's Daily note is gone; the recent one stays.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        #expect(!fm.fileExists(atPath: vaultRoot.appendingPathComponent("Daily/\(f.string(from: oldStart)).md").path))
        #expect(fm.fileExists(atPath: vaultRoot.appendingPathComponent("Daily/\(f.string(from: newStart)).md").path))
    }

    @Test func naviTagAndAttachmentParsing() {
        #expect(VaultCleanup.naviTag(in: "---\ntype: session\ntags: [navi/session]\n---\n# x") == "navi/session")
        #expect(VaultCleanup.naviTag(in: "---\ntags: [work, \"navi/daily\"]\n---\n") == "navi/daily")
        #expect(VaultCleanup.naviTag(in: "---\ntags: [navigation]\n---\n") == nil)
        #expect(VaultCleanup.naviTag(in: "# no frontmatter\ntags: [navi/session]") == nil)
        #expect(VaultCleanup.attachments(in: "a ![[attachments/2026 x.jpg]] b ![[attachments/../../etc.jpg]]") == ["attachments/2026 x.jpg"])
        #expect(VaultCleanup.isEmptyHub("# Title\n\n## Seen in\n\n"))
        #expect(!VaultCleanup.isEmptyHub("# Title\n\nMy notes.\n## Seen in\n"))
    }
}

// MARK: - Delete everything

struct DeleteAllTests {
    @Test func storeDeleteAllLeavesNoTextOnDisk() throws {
        let dir = tempDir("deleteall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let marker = "zebracornflower\(Int.random(in: 1000...9999))"
        for i in 0..<50 { try store.insertFrame(frame(Date().addingTimeInterval(Double(-i * 60)), text: "\(marker) line \(i)")) }
        try store.insertSession(session(Date(), title: marker))
        #expect(try store.frameCount() == 50)

        let r = try store.deleteAll()
        #expect(r.frames == 50)
        #expect(r.sessions == 1)
        #expect(try store.frameCount() == 0)
        #expect(try store.sessionCount() == 0)
        #expect(try store.search(query: marker, limit: 5).isEmpty)
        // secure_delete + VACUUM + WAL truncate: the text is gone from the files themselves.
        for suffix in ["", "-wal"] {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: store.databaseURL.path + suffix))) ?? Data()
            #expect(data.range(of: Data(marker.utf8)) == nil, "in memory.sqlite\(suffix)")
        }
        // Still usable afterwards.
        try store.insertFrame(frame(Date(), text: "fresh start"))
        #expect(try store.frameCount() == 1)
    }

    @Test func eraseFilesRemovesNaviDataAndKeepsUserNotes() throws {
        let dir = tempDir("erase")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = NaviDataPaths(dataDirectory: dir.appendingPathComponent("data", isDirectory: true),
                                  logsDirectory: dir.appendingPathComponent("logs", isDirectory: true),
                                  vaultRoot: dir.appendingPathComponent("vault", isDirectory: true))
        do {
            let store = try MemoryStore(directory: paths.dataDirectory)
            try store.insertFrame(frame(Date(), text: "hello"))
            var s = session(Date(), title: "Budget review")
            s.id = try store.insertSession(s)
            let note = try VaultWriter(root: paths.vaultRoot).write(session: s, digest: digest("Budget review"), frames: [], keepScreenshots: false)
            try store.updateSessionNotePath(sessionID: s.id, notePath: note)
        }
        try write("[]", paths.experienceFile)
        try write("{}", paths.dataDirectory.appendingPathComponent("history.json"))
        try write("x", paths.framesDirectory.appendingPathComponent("2026/09/30/1.jpg"))
        try write("step", paths.logsDirectory.appendingPathComponent("runs/20260930T101010.000/goal.txt"))
        try write("log", paths.logsDirectory.appendingPathComponent("agent-runs.log"))
        let userNote = paths.vaultRoot.appendingPathComponent("Daily/my journal.md")
        try write("# Mine\n", userNote)
        let userTopLevel = paths.vaultRoot.appendingPathComponent("Ideas.md")
        try write("# Ideas\n", userTopLevel)
        let unrelatedLog = paths.logsDirectory.appendingPathComponent("someone-else.txt")
        try write("keep", unrelatedLog)

        let before = DataInventory.scan(paths)
        #expect(before.item(.screenMemory).count == 1)
        #expect(before.item(.screenshots).count == 1)
        #expect(before.item(.journal).count >= 5)          // session, daily, app, topic, entity (+ user's daily)
        #expect(before.item(.taskLogs).count == 1)

        let report = PrivacyData.eraseFiles(paths, includeMemoryDatabase: true)
        let fm = FileManager.default
        #expect(report.notes >= 5)
        #expect(!fm.fileExists(atPath: paths.memoryDatabase.path))
        #expect(!fm.fileExists(atPath: paths.framesDirectory.path))
        #expect(!fm.fileExists(atPath: paths.experienceFile.path))
        #expect(!fm.fileExists(atPath: paths.dataDirectory.appendingPathComponent("history.json").path))
        #expect(!fm.fileExists(atPath: paths.logsDirectory.appendingPathComponent("runs").path))
        #expect(!fm.fileExists(atPath: paths.logsDirectory.appendingPathComponent("agent-runs.log").path))
        #expect(!fm.fileExists(atPath: paths.vaultRoot.appendingPathComponent("Sessions").path))
        #expect(fm.fileExists(atPath: userNote.path))
        #expect(fm.fileExists(atPath: userTopLevel.path))
        #expect(fm.fileExists(atPath: unrelatedLog.path))

        let after = DataInventory.scan(paths)
        #expect(after.item(.screenMemory).bytes == 0)
        #expect(after.item(.screenshots).count == 0)
        #expect(after.item(.journal).count == 1)            // only the user's own daily note
        #expect(after.item(.taskExperience).bytes == 0)
    }
}

// MARK: - Exclusions

struct CaptureExclusionTests {
    @Test func siteNormalisation() {
        #expect(CaptureExclusions.normalizeSite("https://www.Chase.com/login?x=1") == "chase.com")
        #expect(CaptureExclusions.normalizeSite("  secure.chase.com  ") == "secure.chase.com")
        #expect(CaptureExclusions.normalizeSite("user@bank.example.com:8443/path") == "bank.example.com")
        #expect(CaptureExclusions.normalizeSite(".chase.com.") == "chase.com")
        #expect(CaptureExclusions.normalizeSite("chase") == nil)
        #expect(CaptureExclusions.normalizeSite("my bank.com") == nil)
        #expect(CaptureExclusions.normalizeSite("") == nil)
    }

    @Test func siteMatchingCoversSubdomainsOnly() {
        let sites = ["chase.com", "https://www.mybank.co.uk/"]
        #expect(CaptureExclusions.isExcludedSite(url: "https://chase.com/", sites: sites))
        #expect(CaptureExclusions.isExcludedSite(url: "https://secure.chase.com/accounts", sites: sites))
        #expect(CaptureExclusions.isExcludedSite(url: "https://www.chase.com", sites: sites))
        #expect(CaptureExclusions.isExcludedSite(url: "https://login.mybank.co.uk/x", sites: sites))
        #expect(!CaptureExclusions.isExcludedSite(url: "https://notchase.com/", sites: sites))
        #expect(!CaptureExclusions.isExcludedSite(url: "https://chase.com.evil.io/", sites: sites))
        #expect(!CaptureExclusions.isExcludedSite(url: "https://example.com/?ref=chase.com", sites: sites))
        #expect(!CaptureExclusions.isExcludedSite(url: nil, sites: sites))
        #expect(CaptureExclusions.isExcludedSite(url: "https://vault.bitwarden.com/#/vault", sites: CaptureExclusions.defaultSites))
    }

    @Test func appsAndBuiltIns() {
        #expect(CaptureExclusions.isExcludedApp("com.1password.1password", userExcluded: []))
        #expect(CaptureExclusions.isExcludedApp("com.apple.Passwords", userExcluded: []))
        #expect(CaptureExclusions.isExcludedApp("com.example.bank", userExcluded: ["com.example.bank"]))
        #expect(!CaptureExclusions.isExcludedApp("com.apple.Safari", userExcluded: ["com.example.bank"]))
    }

    @Test func privateWindowsAndSecureFields() {
        #expect(CaptureExclusions.isPrivateWindowTitle("Mozilla Firefox Private Browsing"))
        #expect(CaptureExclusions.isPrivateWindowTitle("Bank — Private Browsing"))
        #expect(CaptureExclusions.isPrivateWindowTitle("New tab - [InPrivate] - Microsoft Edge"))
        #expect(!CaptureExclusions.isPrivateWindowTitle("How private browsing works - Wikipedia"))
        #expect(!CaptureExclusions.isPrivateWindowTitle(nil))
        #expect(CaptureExclusions.isSecureRole("AXTextField", subrole: "AXSecureTextField"))
        #expect(!CaptureExclusions.isSecureRole("AXTextField", subrole: nil))
    }
}

// MARK: - Task logs

struct TaskLogTests {
    @Test func offForUsersUnlessChosen() {
        let suite = "navi-tasklogs-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        #expect(!TaskLogs.isEnabled(defaults: d, debugBuild: false))   // a release build that never chose
        #expect(TaskLogs.isEnabled(defaults: d, debugBuild: true))     // a dev build
        d.set(false, forKey: TaskLogs.keepKey)
        #expect(!TaskLogs.isEnabled(defaults: d, debugBuild: true))
        d.set(true, forKey: TaskLogs.keepKey)
        #expect(TaskLogs.isEnabled(defaults: d, debugBuild: false))
        d.set(false, forKey: TaskLogs.keepKey)
        d.set(true, forKey: DeveloperMode.defaultsKey)
        #expect(TaskLogs.isEnabled(defaults: d, debugBuild: false))
    }

    @Test func redactsIdentifiers() {
        let line = "step 3: Type ‘4111 1111 1111 1111’ into Card number; SSN 123-45-6789; call (617) 555-0142"
        let out = TaskLogs.redact(line)
        #expect(!out.contains("4111 1111 1111 1111"))
        #expect(!out.contains("123-45-6789"))
        #expect(!out.contains("555-0142"))
        #expect(out.contains("step 3: Type"))
        let json = TaskLogs.redactJSON(["state": ["fields": ["SSN 123-45-6789", 42]], "ok": true]) as? [String: Any]
        let fields = (json?["state"] as? [String: Any])?["fields"] as? [Any]
        #expect((fields?.first as? String)?.contains("123-45-6789") == false)
        #expect(fields?.last as? Int == 42)
    }

    @Test func purgeByAgeAndSize() throws {
        let dir = tempDir("logs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let runs = dir.appendingPathComponent("runs")
        let old = runs.appendingPathComponent("20260901T000000.000")
        try write("old", old.appendingPathComponent("goal.txt")); try age(old, days: 10, now: now)
        let mid = runs.appendingPathComponent("20260928T000000.000")
        try write(String(repeating: "m", count: 600), mid.appendingPathComponent("payload.json")); try age(mid, days: 3, now: now)
        let fresh = runs.appendingPathComponent("20260930T000000.000")
        try write(String(repeating: "f", count: 600), fresh.appendingPathComponent("payload.json")); try age(fresh, days: 1, now: now)
        let oldLog = dir.appendingPathComponent("agent-runs.1.log")
        try write("old log", oldLog); try age(oldLog, days: 9, now: now)
        let newLog = dir.appendingPathComponent("agent-runs.log")
        try write("new log", newLog)
        let foreign = dir.appendingPathComponent("notes.txt")
        try write("not ours", foreign); try age(foreign, days: 30, now: now)

        // Cap of 1000 bytes: the two 600-byte folders don't both fit — the newest stays.
        let r = TaskLogs.purge(directory: dir, now: now, maxAge: 7 * 86_400, maxBytes: 1000)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: old.path))
        #expect(!fm.fileExists(atPath: mid.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(!fm.fileExists(atPath: oldLog.path))
        #expect(fm.fileExists(atPath: newLog.path))
        #expect(fm.fileExists(atPath: foreign.path))
        #expect(r.itemsRemoved == 3)

        let all = TaskLogs.deleteAll(directory: dir)
        #expect(all.itemsRemoved == 2)   // runs/ and agent-runs.log
        #expect(!fm.fileExists(atPath: runs.path))
        #expect(fm.fileExists(atPath: foreign.path))
    }
}
