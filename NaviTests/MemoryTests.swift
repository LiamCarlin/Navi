import Testing
import Foundation
import CoreGraphics
@testable import Navi

// MARK: - Helpers

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("navi-memory-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func frame(_ ts: Date, app: String = "Safari", bundle: String = "com.apple.Safari", title: String? = "Jev docs",
                   url: String? = nil, text: String, importance: Double = 2, newContext: Bool = false, thumb: String? = nil) -> FrameRecord {
    FrameRecord(timestamp: ts, bundleID: bundle, appName: app, windowTitle: title, url: url, ocrText: text,
                thumbPath: thumb, phash: 0, activity: "browsing", importance: importance, isNewContext: newContext)
}

private func solidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func stripedImage(width: Int, height: Int, stripes: Int, phase: Int = 0) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = width / stripes
    for i in 0..<stripes {
        ctx.setFillColor(CGColor(gray: ((i + phase) % 2 == 0) ? 0.1 : 0.9, alpha: 1))
        ctx.fill(CGRect(x: i * w, y: 0, width: w, height: height))
    }
    return ctx.makeImage()!
}

private func fixedCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

// MARK: - MemoryStore

struct MemoryStoreTests {
    @Test func roundtripAndFTS() throws {
        let dir = tempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        let id1 = try store.insertFrame(frame(now.addingTimeInterval(-60), text: "Jev returns typed decisions with calibrated probabilities."))
        let id2 = try store.insertFrame(frame(now.addingTimeInterval(-30), app: "Xcode", bundle: "com.apple.dt.Xcode", title: "MemoryStore.swift",
                                              text: "final class MemoryStore { func search(query:) }", importance: 2))
        #expect(id1 > 0 && id2 > id1)
        #expect(try store.frameCount() == 2)
        #expect(try store.framesToday() == 2)

        let hits = try store.search(query: "jev probabilities", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id == id1)
        #expect(hits.first?.appName == "Safari")
        #expect(hits.first?.snippet.lowercased().contains("jev") == true)
        #expect((hits.first?.score ?? 0) > 0)

        // Punctuation and stopwords must not break the MATCH expression.
        let hits2 = try store.search(query: "what was I doing in MemoryStore.swift?", limit: 10)
        #expect(hits2.first?.id == id2)

        // Prefix matching.
        #expect(try store.search(query: "calibrat", limit: 5).count == 1)

        // Undigested / digested bookkeeping.
        #expect(try store.undigestedFrames().count == 2)
        try store.markDigested(frameIDs: [id1])
        #expect(try store.undigestedFrames().map(\.id) == [id2])
        #expect(try store.latestFrame()?.id == id2)
    }

    @Test func recencyWeighting() throws {
        let dir = tempDir("recency")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        let old = try store.insertFrame(frame(now.addingTimeInterval(-20 * 86_400), text: "obsidian graph view of my notes"))
        let fresh = try store.insertFrame(frame(now.addingTimeInterval(-60), text: "obsidian graph view of my notes"))
        let hits = try store.search(query: "obsidian graph", limit: 10, now: now)
        #expect(hits.map(\.id) == [fresh, old])
        #expect(hits[0].score > hits[1].score * 5)
        #expect(abs(MemoryStore.weighted(rank: -2, at: now.addingTimeInterval(-7 * 86_400), now: now) - 2 * exp(-1)) < 1e-9)
    }

    @Test func sessionsAreSearchable() throws {
        let dir = tempDir("sessions")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        let s = SessionRecord(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-600), bundleID: "com.apple.Safari",
                              appName: "Safari", url: "https://docs.typesafe.ai", title: "Read the Jev System One docs",
                              summary: "Read the TypeSafe documentation about System One and calibrated probabilities.",
                              topics: ["jev", "system one"], entities: [EntityRef(name: "TypeSafe", type: "company")], importance: 2)
        let id = try store.insertSession(s)
        let hits = try store.search(query: "typesafe", limit: 5, now: now)
        #expect(hits.count == 1)
        #expect(hits.first?.source == .session)
        #expect(hits.first?.id == id)
        #expect(hits.first?.url == "https://docs.typesafe.ai")
        try store.updateSessionNotePath(sessionID: id, notePath: "Sessions/x.md")
        #expect(try store.recentSessions().first?.notePath == "Sessions/x.md")
        #expect(try store.recentSessions().first?.entities == [EntityRef(name: "TypeSafe", type: "company")])
        #expect(try store.sessions(in: DateInterval(start: now.addingTimeInterval(-3600), end: now)).count == 1)
    }

    @Test func sensitiveStubAndPrune() throws {
        let dir = tempDir("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let now = Date()
        let thumb = dir.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8]).write(to: thumb)
        let id = try store.insertFrame(frame(now, text: "my password is hunter2", thumb: thumb.path))
        try store.markSensitiveAndDelete(frameID: id)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        #expect(try store.frame(id: id)?.ocrText == "")
        #expect(try store.search(query: "hunter2", limit: 5).isEmpty)

        let oldThumb = dir.appendingPathComponent("old.jpg")
        try Data([0xFF, 0xD8]).write(to: oldThumb)
        try store.insertFrame(frame(now.addingTimeInterval(-40 * 86_400), text: "ancient history", thumb: oldThumb.path))
        let removed = try store.pruneOlderThan(days: 14, now: now)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: oldThumb.path))
        #expect(try store.frameCount() == 1)
    }

    @Test func ftsQueryBuilder() {
        #expect(MemoryStore.ftsQuery("what was I working on yesterday?", requireAll: true) == "\"yesterday\"*")
        #expect(MemoryStore.ftsQuery("the of and", requireAll: true) == nil)
        #expect(MemoryStore.ftsQuery("Jev docs \"quoted\"", requireAll: false) == "\"jev\"* OR \"docs\"* OR \"quoted\"*")
    }
}

// MARK: - dHash

struct DHashTests {
    @Test func identicalFramesMatch() {
        let a = stripedImage(width: 640, height: 400, stripes: 8)
        let b = stripedImage(width: 640, height: 400, stripes: 8)
        #expect(FrameCapture.dHash(a) == FrameCapture.dHash(b))
        #expect(FrameCapture.hamming(FrameCapture.dHash(a), FrameCapture.dHash(b)) == 0)
    }

    @Test func differentFramesAreFar() {
        let a = stripedImage(width: 640, height: 400, stripes: 8)
        let b = stripedImage(width: 640, height: 400, stripes: 8, phase: 1)
        let flat = solidImage(width: 640, height: 400, gray: 0.5)
        #expect(FrameCapture.hamming(FrameCapture.dHash(a), FrameCapture.dHash(b)) >= CaptureScheduler.hashDistanceThreshold)
        #expect(FrameCapture.hamming(FrameCapture.dHash(a), FrameCapture.dHash(flat)) >= CaptureScheduler.hashDistanceThreshold)
        #expect(FrameCapture.dHash(flat) == 0)
    }

    @Test func hammingCounts() {
        #expect(FrameCapture.hamming(0b1010, 0b0101) == 4)
        #expect(FrameCapture.hamming(UInt64.max, 0) == 64)
    }

    @Test func thumbnailIsBounded() {
        let big = solidImage(width: 3000, height: 1500, gray: 0.3)
        let data = FrameCapture.thumbnailJPEG(big)
        #expect(data != nil)
        #expect((data?.count ?? 0) < 200_000)
        let url = FrameCapture.thumbnailURL(in: URL(fileURLWithPath: "/tmp/frames"), at: Date(timeIntervalSince1970: 1_700_000_000), calendar: fixedCalendar())
        #expect(url.path == "/tmp/frames/2023/11/14/1700000000.jpg")
    }
}

// MARK: - OCR line joining

struct OCRJoinTests {
    @Test func joinsBoxesInReadingOrder() {
        // (text, midY, minX, height) — Vision space, origin bottom-left.
        let boxes: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("world", 0.90, 0.30, 0.02),
            ("Hello", 0.90, 0.10, 0.02),
            ("second line", 0.50, 0.10, 0.02),
            ("footer", 0.05, 0.10, 0.02),
        ]
        let text = FrameCapture.joinBoxes(boxes, maxChars: 6000)
        #expect(text == "Hello  world\nsecond line\nfooter")
        #expect(FrameCapture.joinBoxes(boxes, maxChars: 10).count <= 10)
    }
}

// MARK: - Triage heuristics

struct TriageTests {
    @Test func sensitiveKeywords() {
        #expect(FrameTriage.containsHardSensitive("Enter the CVV on the back of your card"))
        #expect(FrameTriage.containsSoftSensitive("Password: ••••••"))
        #expect(!FrameTriage.containsHardSensitive("Reading about Swift concurrency"))
    }

    @Test func heuristicNewContextAndActivity() {
        let base = FrameTriage.Input(bundleID: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "Navi.xcodeproj", url: nil,
                                     timestamp: Date(), ocrText: String(repeating: "func foo() {} ", count: 10),
                                     previousApp: "com.apple.Safari", previousTitle: "Docs")
        let r = FrameTriage.heuristic(base)
        #expect(r.activity == "coding")
        #expect(r.isNewContext)
        #expect(!r.isSensitive)
        #expect(r.importance == 1)
        #expect(r.source == .heuristic)

        var trivial = base
        trivial.ocrText = "Loading"
        #expect(FrameTriage.heuristic(trivial).importance == 0)

        // Browser tab switches are not new contexts without Jev.
        let tab = FrameTriage.Input(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "B", url: nil, timestamp: Date(),
                                    ocrText: String(repeating: "text ", count: 20), previousApp: "com.apple.Safari", previousTitle: "A")
        #expect(!FrameTriage.heuristic(tab).isNewContext)
        #expect(FrameTriage.heuristic(tab).activity == "browsing")
    }

    @Test func jevStateIsStructured() {
        let i = FrameTriage.Input(bundleID: "b", appName: "App", windowTitle: "T", url: "https://x", timestamp: Date(),
                                  ocrText: "hello", previousApp: "p", previousTitle: "pt")
        let s = FrameTriage.state(for: i)
        #expect(s.contains("[APP] App (b)"))
        #expect(s.contains("[PREVIOUS_CONTEXT] p — pt"))
        #expect(s.hasSuffix("[SCREEN_TEXT]\nhello"))
        #expect(FrameTriage.questions.count == 4)
    }
}

// MARK: - Session grouping

struct SessionGroupingTests {
    @Test func splitsOnGapNewContextAndSustainedAppChange() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let f: [FrameRecord] = [
            frame(t0, text: "a"),
            frame(t0.addingTimeInterval(30), text: "b"),
            frame(t0.addingTimeInterval(60), app: "Slack", bundle: "com.tinyspeck.slackmacgap", text: "blip"),   // single-frame detour
            frame(t0.addingTimeInterval(90), text: "c"),
            frame(t0.addingTimeInterval(120), app: "Xcode", bundle: "com.apple.dt.Xcode", text: "d"),        // sustained change
            frame(t0.addingTimeInterval(150), app: "Xcode", bundle: "com.apple.dt.Xcode", text: "e"),
            frame(t0.addingTimeInterval(180), app: "Xcode", bundle: "com.apple.dt.Xcode", text: "f", newContext: true),
            frame(t0.addingTimeInterval(1500), app: "Xcode", bundle: "com.apple.dt.Xcode", text: "g"),      // > 10 min gap
        ]
        let sessions = Digester.groupSessions(f)
        #expect(sessions.map(\.count) == [4, 2, 1, 1])
        #expect(sessions[0].map(\.ocrText) == ["a", "b", "blip", "c"])
        #expect(sessions[1].map(\.ocrText) == ["d", "e"])
        #expect(Digester.groupSessions([]).isEmpty)
    }

    @Test func sessionRecordPicksDominantAppAndURL() {
        let t0 = Date()
        let f = [
            frame(t0, url: "https://a.com", text: "x"),
            frame(t0.addingTimeInterval(30), url: "https://b.com", text: "y"),
            frame(t0.addingTimeInterval(60), url: "https://b.com", text: "z", importance: 3),
        ]
        let d = DigestResult(title: "Title", summary: "Sum.", topics: [], entities: [], keyFacts: [], links: [])
        let r = Digester.sessionRecord(for: f, digest: d)
        #expect(r.url == "https://b.com")
        #expect(r.appName == "Safari")
        #expect(r.importance == 3)
        #expect(r.start == t0 && r.end == t0.addingTimeInterval(60))
    }
}

// MARK: - Digester parsing / prompt / local

struct DigesterTests {
    @Test func parsesStrictJSON() throws {
        let json = """
        {"title":"Read Jev docs","summary":"Read the TypeSafe docs.","topics":["Jev","System One"],
         "entities":[{"name":"TypeSafe","type":"company"},{"name":"Liam","type":"person"},{"name":"weird","type":"alien"}],
         "key_facts":["Jev answers in 70–500 ms"],"links":["https://docs.typesafe.ai"]}
        """
        let d = try Digester.parse(json)
        #expect(d.title == "Read Jev docs")
        #expect(d.topics == ["jev", "system one"])
        #expect(d.entities.count == 3)
        #expect(d.entities[2].type == "concept")
        #expect(d.keyFacts.count == 1)
        #expect(d.links == ["https://docs.typesafe.ai"])
    }

    @Test func parsesFencedAndProseWrappedJSON() throws {
        let fenced = "```json\n{\"title\":\"T\",\"summary\":\"S\"}\n```"
        #expect(try Digester.parse(fenced).title == "T")
        let prose = "Here is the note:\n{\"title\":\"T2\",\"summary\":\"S2\",\"topics\":\"single\"}\nHope that helps!"
        let d = try Digester.parse(prose)
        #expect(d.title == "T2")
        #expect(d.topics == ["single"])
    }

    @Test func rejectsMalformed() {
        #expect(throws: (any Error).self) { try Digester.parse("Sorry, I cannot help with that.") }
        #expect(throws: (any Error).self) { try Digester.parse("{\"title\": \"unterminated") }
        #expect(throws: (any Error).self) { try Digester.parse("{\"topics\": []}") }
    }

    @Test func providerSelection() {
        #expect(Digester.selectProvider(setting: .auto, hasGemini: true, hasClaude: true) == .gemini(model: Digester.geminiModel))
        #expect(Digester.selectProvider(setting: .auto, hasGemini: false, hasClaude: true) == .claude(model: "claude-haiku-4-5"))
        #expect(Digester.selectProvider(setting: .auto, hasGemini: false, hasClaude: false) == .local)
        #expect(Digester.selectProvider(setting: .localOnly, hasGemini: true, hasClaude: true) == .local)
        #expect(Digester.selectProvider(setting: .claudeHaiku, hasGemini: true, hasClaude: false) == .local)
        #expect(Digester.selectProvider(setting: .gemini, hasGemini: false, hasClaude: true) == .claude(model: "claude-haiku-4-5"))
    }

    @Test func promptIsCompactAndDeduped() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let long = String(repeating: "lorem ipsum dolor sit amet ", count: 400)   // ~10.8k chars
        let f = [
            frame(t0, title: "A", url: "https://a.com", text: long, importance: 1),
            frame(t0.addingTimeInterval(30), title: "A", url: "https://a.com", text: long, importance: 3),   // duplicate text
            frame(t0.addingTimeInterval(60), title: "B", text: "unique second screen", importance: 2),
        ]
        let (text, thumbs) = Digester.buildPrompt(for: f, calendar: fixedCalendar())
        #expect(text.count <= Digester.maxPromptChars)
        #expect(text.contains("[APP] Safari (com.apple.Safari)"))
        #expect(text.contains("[TITLES]\n- A\n- B"))
        #expect(text.contains("[URLS]\n- https://a.com"))
        #expect(text.components(separatedBy: "[SCREEN_TEXT").count - 1 == 2)
        #expect(thumbs.isEmpty)
    }

    @Test func localDigest() {
        let t0 = Date()
        let f = [
            frame(t0, url: "https://www.typesafe.ai/docs", text: "TypeSafe System One returns calibrated probabilities. Jev Jev Jev decisions decisions.", importance: 2),
        ]
        let d = Digester.localDigest(f)
        #expect(d.title == "Safari — Jev docs")
        #expect(d.summary.hasPrefix("TypeSafe System One"))
        #expect(d.topics.contains("Jev"))
        #expect(d.entities.contains(EntityRef(name: "Safari", type: "tool")))
        #expect(d.entities.contains(EntityRef(name: "typesafe.ai", type: "site")))
        #expect(d.links == ["https://www.typesafe.ai/docs"])
    }
}

// MARK: - Gemini parsing

struct GeminiClientTests {
    @Test func parsesCandidates() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"{\\"title\\":\\"x\\"}"}],"role":"model"},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":1200,"candidatesTokenCount":90}}
        """
        let r = try GeminiClient.parse(Data(json.utf8))
        #expect(r.text == "{\"title\":\"x\"}")
        #expect(r.usage.promptTokens == 1200)
        #expect(r.usage.outputTokens == 90)
        #expect(r.finishReason == "STOP")
        #expect(throws: (any Error).self) { try GeminiClient.parse(Data("{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}".utf8)) }
    }
}

// MARK: - Slugging + wikilinks

struct SlugTests {
    @Test func slugStripsForbiddenCharacters() {
        #expect(VaultWriter.slug("Read: Jev/System One? [draft] #1 | \"quoted\" <x>") == "Read JevSystem One draft 1 quoted x")
        #expect(VaultWriter.slug("   many    spaces   ") == "many spaces")
        #expect(VaultWriter.slug("Trailing dots...") == "Trailing dots")
        #expect(VaultWriter.slug("Keep Case & Ünïcödé") == "Keep Case & Ünïcödé")
        let long = VaultWriter.slug(String(repeating: "word ", count: 40))
        #expect(long.count <= 60)
        #expect(!long.hasSuffix(" "))
    }

    @Test func wikilinks() {
        #expect(VaultWriter.wikilink("Entities/Jev") == "[[Entities/Jev]]")
        #expect(VaultWriter.wikilink("Sessions/2026-09-19 1032 Foo", alias: "Foo") == "[[Sessions/2026-09-19 1032 Foo|Foo]]")
        #expect(VaultWriter.wikilink("Apps/Safari", alias: "Safari") == "[[Apps/Safari]]")
        #expect(VaultWriter.sessionStem(start: Date(timeIntervalSince1970: 1_700_000_000), title: "Hello: World", calendar: fixedCalendar()) == "2023-11-14 2213 Hello World")
    }
}

// MARK: - MarkdownNote

struct MarkdownNoteTests {
    @Test func parseAppendRender() {
        let src = "---\ntype: topic\ncount: 1\n---\n\n# Jev\n\n## Seen in\n- one\n\n## Notes\nmine\n"
        var n = MarkdownNote.parse(src)
        #expect(n.get("count") == "1")
        n.set("count", "2")
        n.append("- two", toSection: "Seen in", dedupe: true)
        n.append("- two", toSection: "Seen in", dedupe: true)
        n.append("- new", toSection: "Missing", dedupe: true)
        let out = n.render()
        #expect(out.hasPrefix("---\ntype: topic\ncount: 2\n---\n\n# Jev"))
        #expect(out.contains("## Seen in\n- one\n- two\n\n## Notes\nmine"))
        #expect(out.components(separatedBy: "- two").count == 2)
        #expect(out.hasSuffix("## Missing\n- new\n"))
    }
}

// MARK: - VaultWriter

struct VaultWriterTests {
    @Test func writesLinkedNotes() throws {
        let root = tempDir("vault")
        defer { try? FileManager.default.removeItem(at: root) }
        let cal = fixedCalendar()
        let vault = VaultWriter(root: root, calendar: cal)
        let start = Date(timeIntervalSince1970: 1_700_000_000)          // 2023-11-14 22:13 UTC
        let thumb = root.appendingPathComponent("thumb.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: thumb)
        let frames = [frame(start, text: "x", importance: 2, thumb: thumb.path), frame(start.addingTimeInterval(600), text: "y", importance: 1)]
        var session = SessionRecord(start: start, end: start.addingTimeInterval(600), bundleID: "com.apple.Safari", appName: "Safari",
                                    url: "https://docs.typesafe.ai", title: "Read the Jev docs: \"System One\"",
                                    summary: "Read the TypeSafe docs on Jev. Learned that answers are typed.",
                                    topics: ["jev", "calibrated probabilities"],
                                    entities: [EntityRef(name: "TypeSafe", type: "company"), EntityRef(name: "Liam Carlin", type: "person")],
                                    importance: 2)
        session.id = 1
        let digest = DigestResult(title: session.title, summary: session.summary, topics: session.topics, entities: session.entities,
                                  keyFacts: ["Jev answers in 70–500 ms"], links: ["https://docs.typesafe.ai"])
        let rel = try vault.write(session: session, digest: digest, frames: frames, keepScreenshots: true)
        #expect(rel == "Sessions/2023-11-14 2213 Read the Jev docs System One.md")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".obsidian/app.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent(".obsidian/graph.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Navi/README.md").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("attachments/2023-11-14 2213 Read the Jev docs System One.jpg").path))

        let sessionNote = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        #expect(sessionNote.hasPrefix("---\ntype: session\ntitle: \"Read the Jev docs: \\\"System One\\\"\"\ndate: 2023-11-14\nstart: 2023-11-14T22:13:20Z\n"))
        #expect(sessionNote.contains("topics: [\"jev\", \"calibrated probabilities\"]"))
        #expect(sessionNote.contains("entities: [\"TypeSafe\", \"Liam Carlin\"]"))
        #expect(sessionNote.contains("importance: 2"))
        #expect(sessionNote.contains("# Read the Jev docs: \"System One\""))
        #expect(sessionNote.contains("## Key facts\n- Jev answers in 70–500 ms"))
        #expect(sessionNote.contains("![[attachments/2023-11-14 2213 Read the Jev docs System One.jpg]]"))
        #expect(sessionNote.contains("- [[Daily/2023-11-14]]"))
        #expect(sessionNote.contains("- [[Apps/Safari]]"))
        #expect(sessionNote.contains("[[Topics/jev]], [[Topics/calibrated probabilities]]"))
        #expect(sessionNote.contains("[[Entities/TypeSafe]], [[Entities/Liam Carlin]]"))

        let daily = try String(contentsOf: root.appendingPathComponent("Daily/2023-11-14.md"), encoding: .utf8)
        #expect(daily.hasPrefix("---\ndate: 2023-11-14\ntype: daily\ntags: [navi/daily]\n---"))
        #expect(daily.contains("- **22:13–22:23** [[Sessions/2023-11-14 2213 Read the Jev docs System One|Read the Jev docs: \"System One\"]] — Read the TypeSafe docs on Jev. · [[Apps/Safari]]"))
        #expect(daily.contains("## Topics\n- [[Topics/jev]]\n- [[Topics/calibrated probabilities]]"))
        #expect(daily.contains("## People & things\n- [[Entities/TypeSafe]]\n- [[Entities/Liam Carlin]]"))

        let entity = try String(contentsOf: root.appendingPathComponent("Entities/TypeSafe.md"), encoding: .utf8)
        #expect(entity.hasPrefix("---\ntype: entity\nentity_type: company\nfirst_seen: 2023-11-14\nlast_seen: 2023-11-14\ncount: 1\ntags: [navi/entity]\n---"))
        #expect(entity.contains("## Seen in\n- 2023-11-14 22:13 [[Sessions/2023-11-14 2213 Read the Jev docs System One|Read the Jev docs: \"System One\"]]"))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Topics/calibrated probabilities.md").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Apps/Safari.md").path))

        // Second session next day: hub notes get updated in place, daily topics deduped.
        var s2 = session
        s2.id = 2
        s2.start = start.addingTimeInterval(86_400); s2.end = s2.start.addingTimeInterval(300)
        s2.title = "Jev again"
        let rel2 = try vault.write(session: s2, digest: digest, frames: [], keepScreenshots: true)
        #expect(rel2 == "Sessions/2023-11-15 2213 Jev again.md")
        let entity2 = try String(contentsOf: root.appendingPathComponent("Entities/TypeSafe.md"), encoding: .utf8)
        #expect(entity2.contains("first_seen: 2023-11-14\nlast_seen: 2023-11-15\ncount: 2"))
        #expect(entity2.components(separatedBy: "\n- 2023-11-1").count == 3)

        // Same-day rewrite doesn't duplicate topic bullets.
        var s3 = session; s3.id = 3; s3.title = "Third"
        _ = try vault.write(session: s3, digest: digest, frames: [], keepScreenshots: false)
        let daily2 = try String(contentsOf: root.appendingPathComponent("Daily/2023-11-14.md"), encoding: .utf8)
        #expect(daily2.components(separatedBy: "[[Topics/jev]]").count == 2)
        #expect(daily2.components(separatedBy: "\n- **").count == 3)

        // Notes: 3 sessions + 2 dailies + 2 entities + 2 topics + 1 app + README = 11
        #expect(vault.noteCount() == 11)
    }

    @Test func sessionNameCollisionGetsSuffix() throws {
        let root = tempDir("collide")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultWriter(root: root, calendar: fixedCalendar())
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let s = SessionRecord(start: start, end: start, bundleID: "b", appName: "App", url: nil, title: "Same", summary: "S.", topics: [], entities: [])
        let d = DigestResult(title: "Same", summary: "S.", topics: [], entities: [], keyFacts: [], links: [])
        #expect(try vault.write(session: s, digest: d, frames: [], keepScreenshots: false) == "Sessions/2023-11-14 2213 Same.md")
        #expect(try vault.write(session: s, digest: d, frames: [], keepScreenshots: false) == "Sessions/2023-11-14 2213 Same 2.md")
    }
}

// MARK: - Recall

struct RecallTests {
    @Test func parsesTimeWindows() {
        let cal = fixedCalendar()
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue 2023-11-14 22:13 UTC
        let today = cal.startOfDay(for: now)

        let (w1, q1) = Recall.parseTimeWindow("what was I working on yesterday?", now: now, calendar: cal)
        #expect(w1 == DateInterval(start: today.addingTimeInterval(-86_400), duration: 86_400))
        #expect(q1 == "what was i working on")

        let (w2, q2) = Recall.parseTimeWindow("that jev article this morning", now: now, calendar: cal)
        #expect(w2?.start == today.addingTimeInterval(5 * 3600))
        #expect(q2 == "that jev article")

        let (w3, _) = Recall.parseTimeWindow("3 days ago", now: now, calendar: cal)
        #expect(w3?.start == today.addingTimeInterval(-3 * 86_400))

        let (w4, q4) = Recall.parseTimeWindow("the slack thread on monday", now: now, calendar: cal)
        #expect(w4?.start == today.addingTimeInterval(-86_400))
        #expect(q4 == "the slack thread")

        let (w5, q5) = Recall.parseTimeWindow("obsidian graph", now: now, calendar: cal)
        #expect(w5 == nil && q5 == "obsidian graph")
    }

    @Test func searchFallsBackToSessionListing() async throws {
        let dir = tempDir("recall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MemoryStore(directory: dir)
        let cal = fixedCalendar()
        let now = Date()
        let yesterday = cal.startOfDay(for: now).addingTimeInterval(-86_400 + 10 * 3600)
        try store.insertSession(SessionRecord(start: yesterday, end: yesterday.addingTimeInterval(600), bundleID: "com.apple.dt.Xcode",
                                              appName: "Xcode", url: nil, title: "Built MemoryStore", summary: "Wrote the SQLite store. Added FTS5.",
                                              topics: ["sqlite"], entities: [], importance: 2))
        try store.insertFrame(frame(now.addingTimeInterval(-60), text: "unrelated today text about kittens"))
        let recall = Recall(store: store, calendar: cal)

        let listed = await recall.search(query: "what did I do yesterday?", limit: 10, now: now)
        #expect(listed.count == 1)
        #expect(listed.first?.id == -1)
        #expect(listed.first?.windowTitle == "Built MemoryStore")
        #expect(listed.first?.snippet == "Wrote the SQLite store.")

        let termed = await recall.search(query: "sqlite yesterday", limit: 10, now: now)
        #expect(termed.count == 1 && termed.first?.id == -1)

        let none = await recall.search(query: "kittens yesterday", limit: 10, now: now)
        #expect(none.isEmpty)

        let ctx = await recall.context(for: "sqlite", limit: 5, now: now)
        #expect(ctx.hasPrefix("[SCREEN_MEMORY]\n- "))
        #expect(ctx.contains("Xcode · Built MemoryStore"))
    }
}
