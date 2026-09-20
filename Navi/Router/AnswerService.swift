import Foundation

/// Claude-backed text answers for the panel ("Ask Navi: …").
///
/// Streams markdown deltas from `ClaudeClient.stream`, with a system prompt
/// carrying the moment's context (time, frontmost app, optional clipboard,
/// optional screen-memory hits). Also exposes `complete(prompt:)` for other
/// modules that need a one-shot completion.
final class AnswerService: AnswerProviding, @unchecked Sendable {
    let claude: ClaudeClient

    init(claude: ClaudeClient) { self.claude = claude }

    static let missingKeyMessage =
        "Navi needs an Anthropic API key to answer questions. Add one in **Navi → AI Providers** (open the Navi window from the menu bar)."

    // MARK: - AnswerProviding

    func streamAnswer(query: String, context: QueryContext, memory: [MemoryHit]) -> AsyncThrowingStream<String, Error> {
        let system = Self.systemPrompt(query: query, context: context, memory: memory)
        return stream(system: system, user: query, maxTokens: 4000, effort: "medium")
    }

    /// One structured follow-up for an ambiguous request: a question plus 2–4
    /// likely interpretations, each a complete request Navi can run as-is.
    func clarification(query: String, context: QueryContext) async throws -> ClarificationPrompt {
        guard claude.isConfigured else { throw NaviError.missingAPIKey(.anthropic) }
        let system = Self.systemPrompt(query: query, context: context, memory: []) + "\n\n" + Self.clarificationInstructions
        let model = await MainActor.run { NaviSettings.shared.answerModel }
        let text = try await claude.complete(model: model, system: system, prompt: query, maxTokens: 400, effort: "low")
        guard let prompt = Self.parseClarification(text, query: query) else {
            throw NaviError.decoding("Clarification was not valid JSON: \(text.prefix(120))")
        }
        return prompt
    }

    static let clarificationInstructions = """
    The request below is too ambiguous to carry out. Do NOT answer or perform it. Instead reply with ONLY a JSON \
    object, no prose and no code fence:
    {"question": "<one short question, one sentence>", "options": ["<interpretation 1>", "<interpretation 2>", ...]}
    Rules for options:
    - 2 to 4 options, most likely first.
    - Each option is the user's request rewritten as a COMPLETE, specific instruction Navi could run with no further \
      questions, in the user's voice (e.g. "Email Bob Smith to move tomorrow's lunch to 1 pm").
    - Keep each under 14 words. No "other" / "something else" option — the user can type their own.
    """

    /// Parses the JSON Claude returns for `clarification` (tolerates code fences and surrounding prose).
    static func parseClarification(_ text: String, query: String) -> ClarificationPrompt? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let question = (obj["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return nil }
        var seen = Set<String>()
        let options = ((obj["options"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return ClarificationPrompt(originalQuery: query, question: question,
                                   options: Array(options.prefix(ClarificationPrompt.maxOptions)))
    }

    /// One-shot completion for other modules (e.g. clarification text, titles).
    func complete(prompt: String, system: String? = nil, maxTokens: Int = 1024) async throws -> String {
        guard claude.isConfigured else { throw NaviError.missingAPIKey(.anthropic) }
        let model = await MainActor.run { NaviSettings.shared.answerModel }
        return try await claude.complete(model: model, system: system, prompt: prompt, maxTokens: maxTokens, effort: "low")
    }

    // MARK: - Internals

    private func stream(system: String, user: String, maxTokens: Int, effort: String) -> AsyncThrowingStream<String, Error> {
        guard claude.isConfigured else {
            return AsyncThrowingStream { c in c.yield(Self.missingKeyMessage); c.finish() }
        }
        let claude = self.claude
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = await MainActor.run { NaviSettings.shared.answerModel }
                    let inner = claude.stream(model: model, system: system,
                                              messages: [["role": "user", "content": user]],
                                              maxTokens: maxTokens, effort: effort)
                    for try await chunk in inner {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt (pure)

    static let clipboardTriggers = ["this", "clipboard", "selected", "selection", "copied", "paste", "pasted"]

    static func systemPrompt(query: String, context: QueryContext, memory: [MemoryHit],
                             now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.timeZone = timeZone
        df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var lines: [String] = []
        lines.append("You are Navi, a fast assistant that lives in a Spotlight-style panel on the user's Mac (macOS).")
        lines.append("Now: \(df.string(from: now)) (\(timeZone.identifier), \(timeZone.abbreviation() ?? "")).")
        if let app = context.frontmostAppName ?? context.frontmostApp {
            var s = "Frontmost app: \(app)"
            if let t = context.frontmostWindowTitle, !t.isEmpty { s += " — window: “\(t)”" }
            lines.append(s + ".")
        }
        let lower = query.lowercased()
        let wordsInQuery = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let referencesClipboard = clipboardTriggers.contains { wordsInQuery.contains($0) }
        if referencesClipboard {
            if let sel = context.selectedText, !sel.isEmpty {
                lines.append("Selected text in the frontmost app:\n\"\"\"\n\(sel.prefix(4000))\n\"\"\"")
            }
            if let clip = context.clipboard, !clip.isEmpty {
                lines.append("Clipboard contents:\n\"\"\"\n\(clip.prefix(4000))\n\"\"\"")
            }
        }
        if !memory.isEmpty {
            lines.append("Relevant moments from the user's screen memory (most relevant first):")
            lines.append(memory.prefix(8).map { formatMemoryHit($0, timeZone: timeZone) }.joined(separator: "\n"))
        }
        lines.append("""
        Rules:
        - Answer directly. No preamble, no restating the question.
        - Keep it Spotlight-sized: a few short lines or a compact list unless the user clearly wants depth.
        - Use light markdown only (bold, bullets, inline code, short numbered steps). No headings, no tables unless essential.
        - Be concrete and correct; if you're unsure, say so in a few words rather than hedging at length.
        - Suggest one follow-up only when it is genuinely useful.
        """)
        return lines.joined(separator: "\n\n")
    }

    static func formatMemoryHit(_ h: MemoryHit, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.timeZone = timeZone
        df.dateFormat = "MMM d h:mm a"
        var head = "[\(df.string(from: h.timestamp)) · \(h.appName)"
        if let t = h.windowTitle, !t.isEmpty { head += " · \(t.prefix(80))" }
        head += "]"
        let snippet = h.snippet.replacingOccurrences(of: "\n", with: " ").prefix(400)
        return "- \(head) \(snippet)"
    }
}
