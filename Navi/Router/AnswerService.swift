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

    /// Streams a single clarifying question for an ambiguous request.
    func streamClarification(query: String, context: QueryContext) -> AsyncThrowingStream<String, Error> {
        let system = Self.systemPrompt(query: query, context: context, memory: []) + """


        The request below is ambiguous. Do NOT answer it. Instead, ask exactly ONE short clarifying question \
        (one sentence) that would let you act on it, optionally followed by 2–3 likely interpretations as a bullet list.
        """
        return stream(system: system, user: query, maxTokens: 300, effort: "low")
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
