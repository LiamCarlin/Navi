import Foundation

/// What the digest LLM returns for one session.
struct DigestResult: Sendable, Equatable {
    var title: String
    var summary: String
    var topics: [String]
    var entities: [EntityRef]
    var keyFacts: [String]
    var links: [String]

    static let empty = DigestResult(title: "", summary: "", topics: [], entities: [], keyFacts: [], links: [])
}

/// Groups undigested frames into sessions, asks a cheap LLM (or local
/// heuristics) for a structured summary, stores the session and writes the
/// Obsidian note.
final class Digester: @unchecked Sendable {
    enum Provider: Equatable, Sendable {
        case gemini(model: String)
        case claude(model: String)
        case local

        var label: String {
            switch self {
            case .gemini(let m): return "Gemini \(m)"
            case .claude(let m): return "Claude \(m)"
            case .local: return "local"
            }
        }
        var supportsImages: Bool { self != .local }
    }

    static let geminiModel = GeminiClient.defaultModel
    static let claudeModel = "claude-haiku-4-5"
    static let sessionGap: TimeInterval = 10 * 60
    /// Periodic runs leave the trailing (still-open) session alone if its last
    /// frame is newer than this, so an ongoing task isn't split in two.
    static let openSessionGrace: TimeInterval = 5 * 60
    /// Frames older than this are digested locally if the LLM keeps failing.
    static let backlogFallbackAge: TimeInterval = 24 * 3600
    static let maxPromptChars = 8000
    static let maxFramesInPrompt = 4
    static let maxThumbnails = 2

    let store: MemoryStore
    let vault: VaultWriter
    let claude: ClaudeClient
    let gemini: GeminiClient
    private let updateStatus: CaptureScheduler.StatusUpdate
    private let running = NSLock()
    private var isRunning = false

    init(store: MemoryStore, vault: VaultWriter, claude: ClaudeClient, gemini: GeminiClient,
         updateStatus: @escaping CaptureScheduler.StatusUpdate) {
        self.store = store; self.vault = vault; self.claude = claude; self.gemini = gemini
        self.updateStatus = updateStatus
    }

    // MARK: Provider selection

    /// `.auto` → Gemini Flash-Lite if a key exists, else Claude Haiku, else local.
    static func selectProvider(setting: DigestProvider, hasGemini: Bool, hasClaude: Bool) -> Provider {
        switch setting {
        case .auto:
            if hasGemini { return .gemini(model: geminiModel) }
            if hasClaude { return .claude(model: claudeModel) }
            return .local
        case .gemini:
            if hasGemini { return .gemini(model: geminiModel) }
            return hasClaude ? .claude(model: claudeModel) : .local
        case .claudeHaiku:
            return hasClaude ? .claude(model: claudeModel) : .local
        case .localOnly:
            return .local
        }
    }

    // MARK: Run

    /// Digests everything pending. Returns the number of sessions written.
    /// `includeOpen` (Digest Now) also folds in the still-active trailing session.
    @discardableResult
    func run(includeOpen: Bool, now: Date = Date()) async throws -> Int {
        let alreadyRunning = running.withLock { () -> Bool in
            let r = isRunning; isRunning = true; return r
        }
        guard !alreadyRunning else { return 0 }
        defer { running.withLock { isRunning = false } }

        let setting = await MainActor.run { NaviSettings.shared.digestProvider }
        let keep = await MainActor.run { NaviSettings.shared.memoryKeepScreenshots }
        let provider = Self.selectProvider(setting: setting, hasGemini: gemini.isConfigured, hasClaude: claude.isConfigured)

        let frames = try store.undigestedFrames()
        var sessions = Self.groupSessions(frames)
        if !includeOpen, let last = sessions.last?.last, now.timeIntervalSince(last.timestamp) < Self.openSessionGrace {
            sessions.removeLast()
        }
        guard !sessions.isEmpty else { return 0 }
        Log.memory.info("Digest: \(frames.count) frames → \(sessions.count) sessions via \(provider.label, privacy: .public)")

        var written = 0
        for session in sessions {
            let ids = session.map(\.id)
            let maxImportance = session.map(\.importance).max() ?? 0
            let hasText = session.contains { !$0.ocrText.isEmpty }
            guard maxImportance >= 1, hasText else {
                try store.markDigested(frameIDs: ids)
                continue
            }
            let (result, usedProvider): (DigestResult, Provider)
            do {
                let d = try await summarize(session, provider: provider)
                result = d; usedProvider = provider
            } catch {
                let oldest = session.first?.timestamp ?? now
                if provider != .local, now.timeIntervalSince(oldest) > Self.backlogFallbackAge {
                    Log.memory.warning("Digest LLM failed for old session; using local digest: \(error.localizedDescription)")
                    result = Self.localDigest(session); usedProvider = .local
                } else {
                    Log.memory.error("Digest failed: \(error.localizedDescription)")
                    updateStatus { $0.lastError = "Digest failed: \(error.localizedDescription)" }
                    throw error
                }
            }

            var record = Self.sessionRecord(for: session, digest: result)
            let id = try store.insertSession(record)
            record.id = id
            do {
                let notePath = try vault.write(session: record, digest: result, frames: session, keepScreenshots: keep)
                try store.updateSessionNotePath(sessionID: id, notePath: notePath)
            } catch {
                Log.memory.error("Vault write failed: \(error.localizedDescription)")
                updateStatus { $0.lastError = "Vault write failed: \(error.localizedDescription)" }
            }
            try store.markDigested(frameIDs: ids)
            written += 1
            let n = session.count
            await MainActor.run { NaviSettings.shared.usageDigestFrames += n }
            Log.memory.info("Session #\(id) \"\(record.title, privacy: .public)\" (\(n) frames, \(usedProvider.label, privacy: .public))")
        }
        let count = vault.noteCount()
        updateStatus { s in
            s.lastDigestAt = now
            s.vaultNoteCount = count
            if s.lastError?.hasPrefix("Digest failed") == true || s.lastError?.hasPrefix("Vault write") == true { s.lastError = nil }
        }
        return written
    }

    // MARK: Session grouping

    /// Splits chronologically-ordered frames into sessions on: a gap > 10 min,
    /// Jev's `is_new_context`, or an app change that lasts ≥ 2 frames (a
    /// single-frame detour into another app stays inside the session).
    static func groupSessions(_ frames: [FrameRecord], gap: TimeInterval = sessionGap) -> [[FrameRecord]] {
        var sessions: [[FrameRecord]] = []
        var current: [FrameRecord] = []
        for (i, f) in frames.enumerated() {
            if let last = current.last, let first = current.first {
                let tooLong = f.timestamp.timeIntervalSince(last.timestamp) > gap
                let appChanged = f.bundleID != first.bundleID
                let next = i + 1 < frames.count ? frames[i + 1] : nil
                let sustained = appChanged && (next == nil || next!.bundleID == f.bundleID)
                let newContext = f.isNewContext && !f.ocrText.isEmpty
                if tooLong || newContext || sustained {
                    sessions.append(current)
                    current = []
                }
            }
            current.append(f)
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }

    // MARK: Prompt

    static let systemPrompt = """
    You are the memory digester for Navi, a macOS assistant. You receive on-screen text (OCR) and \
    optionally screenshots from one stretch of the user's computer activity, and you write a concise \
    memory note so the user can later ask "what was I doing?".
    Respond with ONLY a JSON object, no prose, no markdown fences:
    {"title": string (≤ 60 chars, specific), "summary": string (2–4 sentences, past tense, concrete: name \
    files, people, sites, decisions), "topics": [2–6 short lowercase noun phrases], \
    "entities": [{"name": string, "type": "person|project|company|tool|site|file|concept"}], \
    "key_facts": [≤ 6 concrete facts worth remembering], "links": [URLs seen]}
    Rules: never invent details not present in the input; never include passwords, codes or secrets; \
    prefer proper nouns for entities; keep topic names reusable across days (e.g. "swift concurrency", \
    not "the thing I read").
    """

    /// Compact, structured prompt for one session. Returns the text plus the
    /// thumbnails worth attaching (highest-importance frames with a file on disk).
    static func buildPrompt(for frames: [FrameRecord], maxChars: Int = maxPromptChars,
                            calendar: Calendar = .current) -> (text: String, thumbnailPaths: [String]) {
        guard let first = frames.first, let last = frames.last else { return ("", []) }
        let time = DateFormatter()
        time.calendar = calendar; time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        let minutes = max(1, Int(last.timestamp.timeIntervalSince(first.timestamp) / 60))

        var lines: [String] = []
        let apps = uniqueOrdered(frames.map { "\($0.appName) (\($0.bundleID))" })
        lines.append("[APP] " + apps.prefix(3).joined(separator: "; "))
        lines.append("[TIME] \(day.string(from: first.timestamp)) \(time.string(from: first.timestamp))–\(time.string(from: last.timestamp)) (\(minutes) min, \(frames.count) frames)")
        lines.append("[ACTIVITY] " + uniqueOrdered(frames.map(\.activity)).joined(separator: ", "))
        let titles = uniqueOrdered(frames.compactMap { $0.windowTitle }.filter { !$0.isEmpty })
        if !titles.isEmpty { lines.append("[TITLES]\n" + titles.prefix(6).map { "- \($0)" }.joined(separator: "\n")) }
        let urls = uniqueOrdered(frames.compactMap { $0.url }.filter { !$0.isEmpty })
        if !urls.isEmpty { lines.append("[URLS]\n" + urls.prefix(6).map { "- \($0)" }.joined(separator: "\n")) }

        var used = lines.joined(separator: "\n").count
        var seenKeys = Set<String>()
        var picked: [FrameRecord] = []
        for f in frames.sorted(by: { $0.importance == $1.importance ? $0.timestamp < $1.timestamp : $0.importance > $1.importance }) {
            guard !f.ocrText.isEmpty else { continue }
            let key = normalizedKey(f.ocrText)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            picked.append(f)
            if picked.count >= maxFramesInPrompt { break }
        }
        let ordered = picked.sorted { $0.timestamp < $1.timestamp }
        for (n, f) in ordered.enumerated() {
            // Share the remaining budget across the frames still to add.
            let remaining = max(0, maxChars - used - 40 * (ordered.count - n))
            let budget = remaining / (ordered.count - n)
            guard budget > 200 else { break }
            let text = String(f.ocrText.prefix(budget))
            let block = "[SCREEN_TEXT \(n + 1) @ \(time.string(from: f.timestamp))]\n\(text)"
            lines.append(block)
            used += block.count + 1
        }

        let thumbs = picked.compactMap { $0.thumbPath }.filter { FileManager.default.fileExists(atPath: $0) }.prefix(maxThumbnails)
        return (lines.joined(separator: "\n"), Array(thumbs))
    }

    static func normalizedKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(300))
    }

    static func uniqueOrdered(_ items: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for i in items where !seen.contains(i) { seen.insert(i); out.append(i) }
        return out
    }

    // MARK: LLM calls

    func summarize(_ frames: [FrameRecord], provider: Provider) async throws -> DigestResult {
        guard provider != .local else { return Self.localDigest(frames) }
        // One cloud run per digested session (`X-Navi-Run`), routed to `/v1/digest` under `recall_digest`.
        return try await CloudRun.$current.withValue(CloudRun(feature: .recallDigest)) {
            try await summarizeWithModel(frames, provider: provider)
        }
    }

    private func summarizeWithModel(_ frames: [FrameRecord], provider: Provider) async throws -> DigestResult {
        let (prompt, thumbs) = Self.buildPrompt(for: frames)
        let images: [Data] = thumbs.compactMap { FileManager.default.contents(atPath: $0) }
        var text = try await complete(prompt: prompt, images: images, provider: provider)
        do {
            return try Self.parse(text)
        } catch {
            Log.memory.warning("Digest JSON parse failed, retrying once: \(error.localizedDescription)")
            text = try await complete(prompt: prompt + "\n\nReturn only JSON.", images: images, provider: provider)
            return try Self.parse(text)
        }
    }

    private func complete(prompt: String, images: [Data], provider: Provider) async throws -> String {
        switch provider {
        case .gemini(let model):
            let reply = try await gemini.generate(model: model, system: Self.systemPrompt, prompt: prompt,
                                                  images: images.map { GeminiClient.ImagePart(data: $0) },
                                                  jsonMode: true, maxOutputTokens: 1024)
            Log.memory.debug("Gemini digest: \(reply.usage.promptTokens) in / \(reply.usage.outputTokens) out")
            return reply.text
        case .claude(let model):
            var content: [[String: Any]] = images.map {
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
            }
            content.append(["type": "text", "text": prompt])
            let m = try await claude.create(model: model, system: Self.systemPrompt,
                                            messages: [["role": "user", "content": content]],
                                            maxTokens: 1024, effort: "low", thinking: nil)
            return m.text
        case .local:
            return ""
        }
    }

    // MARK: Parsing

    /// Tolerant JSON extraction: strips fences/prose around the object, then
    /// coerces each field. Throws if there is no usable object or no title/summary.
    static func parse(_ raw: String) throws -> DigestResult {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close else {
            throw NaviError.decoding("digest response contains no JSON object")
        }
        let body = String(s[open...close])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw NaviError.decoding("digest response is not valid JSON")
        }
        let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !summary.isEmpty else { throw NaviError.decoding("digest JSON missing title/summary") }
        let topics = stringList(obj["topics"]).map { $0.lowercased() }
        var entities: [EntityRef] = []
        if let arr = obj["entities"] as? [Any] {
            for e in arr {
                if let d = e as? [String: Any], let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    let type = (d["type"] as? String ?? "concept").lowercased()
                    entities.append(EntityRef(name: name, type: validEntityTypes.contains(type) ? type : "concept"))
                } else if let name = e as? String, !name.isEmpty {
                    entities.append(EntityRef(name: name, type: "concept"))
                }
            }
        }
        return DigestResult(title: title.isEmpty ? String(summary.prefix(60)) : title,
                            summary: summary,
                            topics: uniqueOrdered(topics),
                            entities: uniqueEntities(entities),
                            keyFacts: stringList(obj["key_facts"]),
                            links: uniqueOrdered(stringList(obj["links"])))
    }

    static let validEntityTypes: Set<String> = ["person", "project", "company", "tool", "site", "file", "concept"]

    private static func stringList(_ v: Any?) -> [String] {
        if let arr = v as? [Any] {
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let s = v as? String, !s.isEmpty { return [s] }
        return []
    }

    private static func uniqueEntities(_ list: [EntityRef]) -> [EntityRef] {
        var seen = Set<String>(); var out: [EntityRef] = []
        for e in list {
            let k = e.name.lowercased()
            if !seen.contains(k) { seen.insert(k); out.append(e) }
        }
        return out
    }

    // MARK: Local (no-LLM) digest

    static func localDigest(_ frames: [FrameRecord]) -> DigestResult {
        let best = frames.filter { !$0.ocrText.isEmpty }
            .sorted { $0.importance == $1.importance ? $0.timestamp < $1.timestamp : $0.importance > $1.importance }
        let app = frames.first?.appName ?? "Unknown"
        let title = uniqueOrdered(frames.compactMap(\.windowTitle).filter { !$0.isEmpty }).first
        let noteTitle = String((title.map { "\(app) — \($0)" } ?? app).prefix(80))
        let raw = best.first?.ocrText ?? ""
        let summary = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300))
        var entities = [EntityRef(name: app, type: "tool")]
        let urls = uniqueOrdered(frames.compactMap(\.url).filter { !$0.isEmpty })
        for host in uniqueOrdered(urls.compactMap { URL(string: $0)?.host }) {
            entities.append(EntityRef(name: host.replacingOccurrences(of: "www.", with: ""), type: "site"))
        }
        return DigestResult(title: noteTitle, summary: summary,
                            topics: keywords(best.map(\.ocrText), max: 5),
                            entities: entities, keyFacts: [], links: urls)
    }

    /// Top salient terms across the session's OCR: term frequency with a
    /// length + capitalisation boost, minus stopwords and numbers.
    static func keywords(_ texts: [String], max limit: Int) -> [String] {
        var score: [String: Double] = [:]
        var display: [String: String] = [:]
        for text in texts {
            for chunk in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                let w = String(chunk)
                guard w.count >= 3, w.count <= 32, w.first!.isLetter, !w.allSatisfy(\.isNumber) else { continue }
                let key = w.lowercased()
                guard !MemoryStore.stopwords.contains(key), !uiNoise.contains(key) else { continue }
                let boost = (w.first!.isUppercase ? 1.6 : 1.0) * (1 + Double(min(w.count, 12)) / 12)
                score[key, default: 0] += boost
                if display[key] == nil || (w.first!.isUppercase && display[key]!.first!.isLowercase) { display[key] = w }
            }
        }
        return score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { display[$0.key] ?? $0.key }
    }

    static let uiNoise: Set<String> = [
        "file", "edit", "view", "window", "help", "search", "home", "back", "next", "menu", "close", "open",
        "save", "cancel", "settings", "https", "http", "with", "from", "this", "that", "your", "more", "page",
        "click", "here", "sign", "login", "logout", "share", "copy", "paste", "undo", "redo", "true", "false",
        "null", "return", "import", "self", "func", "class", "struct", "void", "const", "static", "public",
        "private", "string", "print", "https://", "com", "www",
    ]

    // MARK: Record assembly

    static func sessionRecord(for frames: [FrameRecord], digest: DigestResult) -> SessionRecord {
        let first = frames.first!, last = frames.last!
        var urlCounts: [String: Int] = [:]
        for u in frames.compactMap(\.url) where !u.isEmpty { urlCounts[u, default: 0] += 1 }
        let url = urlCounts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        var appCounts: [String: (String, Int)] = [:]
        for f in frames { appCounts[f.bundleID, default: (f.appName, 0)].1 += 1 }
        let (bundle, (app, _)) = appCounts.max { $0.value.1 < $1.value.1 } ?? (first.bundleID, (first.appName, 0))
        let title = digest.title.isEmpty ? (first.windowTitle ?? app) : digest.title
        return SessionRecord(start: first.timestamp, end: last.timestamp, bundleID: bundle, appName: app, url: url,
                             title: String(title.prefix(120)), summary: digest.summary,
                             topics: digest.topics, entities: digest.entities,
                             importance: frames.map(\.importance).max() ?? 1, notePath: nil)
    }
}
