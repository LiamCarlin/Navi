import Foundation

/// Raw-HTTP client for the Claude Messages API (no SDK exists for Swift).
///
///   POST https://api.anthropic.com/v1/messages
///   x-api-key: <ANTHROPIC_API_KEY>   anthropic-version: 2023-06-01
///
/// Two entry points:
///   • `stream(...)`  – SSE text streaming for answers.
///   • `create(...)`  – full JSON round-trip (used by the computer-use agent loop,
///                      which needs `tool_use` blocks and sends images back).
///
/// Models (Sept 2026): claude-opus-5 (default), claude-sonnet-5, claude-haiku-4-5.
/// Thinking on Opus 5 is adaptive by default; use `output_config.effort` to tune.
/// Prefill is not supported on 4.6+ models. Computer use tool: `computer_toolset_20260801`
/// (no beta header) — see Agent/ComputerAgent.swift.
final class ClaudeClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    private let session: URLSession
    /// The account transport (`POST <cloudBaseURL>/v1/claude`, SSE passed
    /// through); used whenever `cloud.isActive`, else the key in the Keychain.
    let cloud: CloudTransport

    init(cloud: CloudTransport = .shared) {
        self.cloud = cloud
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.httpAdditionalHeaders = ["User-Agent": "Navi/0.1 (macOS)"]
        session = URLSession(configuration: cfg)
    }

    var isConfigured: Bool { cloud.isActive || Keychain.has(.anthropic) }

    /// Opens the TCP+TLS connection to the API host ahead of the first real
    /// call (`GET /v1/models`, free). Saves ~300 ms on the first answer,
    /// agent fallback or text-helper request. Fire-and-forget; never throws.
    func warm() {
        if cloud.isActive { cloud.warm(); return }
        guard let key = Keychain.get(.anthropic), !key.isEmpty else { return }
        var req = URLRequest(url: baseURL.deletingLastPathComponent().appendingPathComponent("models"))
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 5
        Task.detached(priority: .userInitiated) { [session] in
            let start = Date()
            _ = try? await session.data(for: req)
            Log.claude.debug("Claude connection warmed in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    /// `output_config.effort` + adaptive thinking exist on Opus/Sonnet 4.6+ and 5;
    /// Haiku 4.5 rejects them.
    static func supportsEffort(_ model: String) -> Bool { !model.contains("haiku") }

    /// `ANTHROPIC_BASE_URL` override (proxies / gateways like Respan).
    private var baseURL: URL {
        if let s = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"], let u = URL(string: s) {
            return u.appendingPathComponent("v1/messages")
        }
        return Self.endpoint
    }

    /// Builds the request for the active transport. Through the account the
    /// body is the exact Messages body sent to `/v1/claude` (`/v1/digest` for
    /// Recall digests) with `anthropic-version` preserved and the feature/run
    /// headers added; the bearer is attached by `CloudTransport` on send.
    func request(body: [String: Any], betas: [String] = [], fallbackFeature: CloudFeature) throws -> URLRequest {
        var headers = ["anthropic-version": Self.apiVersion]
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        if cloud.isActive {
            let run = CloudRun.resolve(fallback: fallbackFeature)
            return try cloud.request(path: run.feature.claudePath, json: body, run: run, extraHeaders: headers)
        }
        guard let key = Keychain.get(.anthropic), !key.isEmpty else { throw NaviError.missingAPIKey(.anthropic) }
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Streaming text

    /// Streams text deltas. `system` may be nil. `messages` are raw API message dicts.
    func stream(model: String, system: String?, messages: [[String: Any]],
                maxTokens: Int = 8000, effort: String = "medium",
                tools: [[String: Any]] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "messages": messages,
                    ]
                    if Self.supportsEffort(model) { body["output_config"] = ["effort": effort] }
                    if let system { body["system"] = system }
                    if !tools.isEmpty { body["tools"] = tools }
                    let req = try request(body: body, fallbackFeature: .answer)
                    let bytes: URLSession.AsyncBytes
                    if cloud.isActive {
                        (bytes, _) = try await cloud.bytes(req)   // 401 refresh / 402 / 403 decided before the first byte
                    } else {
                        let (b, resp) = try await session.bytes(for: req)
                        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response") }
                        if !(200..<300).contains(http.statusCode) {
                            var text = ""
                            for try await line in b.lines { text += line }
                            throw NaviError.http(status: http.statusCode, body: text)
                        }
                        bytes = b
                    }
                    var inTok = 0, outTok = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_start":
                            inTok = ((json["message"] as? [String: Any])?["usage"] as? [String: Any])?["input_tokens"] as? Int ?? 0
                        case "message_delta":
                            outTok = (json["usage"] as? [String: Any])?["output_tokens"] as? Int ?? outTok
                        case "error":
                            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                            throw NaviError.other(msg)
                        case "message_stop":
                            break
                        default: break
                        }
                    }
                    let i = inTok, o = outTok
                    await MainActor.run {
                        NaviSettings.shared.usageClaudeInputTokens += i
                        NaviSettings.shared.usageClaudeOutputTokens += o
                    }
                    continuation.finish()
                } catch {
                    Log.claude.error("stream failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Non-streaming (tool loops)

    struct Message: Sendable {
        var id: String
        var stopReason: String?
        var content: [[String: Any]]      // raw content blocks
        var inputTokens: Int
        var outputTokens: Int

        var text: String {
            content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
        var toolUses: [[String: Any]] { content.filter { $0["type"] as? String == "tool_use" } }
    }

    /// One full round-trip. Caller owns the message list (append `content` back
    /// as the assistant turn, then a user turn with `tool_result` blocks).
    func create(model: String, system: Any?, messages: [[String: Any]],
                tools: [[String: Any]] = [], maxTokens: Int = 4096,
                effort: String = "medium", thinking: [String: Any]? = ["type": "adaptive"],
                betas: [String] = []) async throws -> Message {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if Self.supportsEffort(model) {
            body["output_config"] = ["effort": effort]
            if let thinking { body["thinking"] = thinking }
        }
        if let system { body["system"] = system }
        if !tools.isEmpty { body["tools"] = tools }
        let req = try request(body: body, betas: betas, fallbackFeature: .task)
        let data: Data
        if cloud.isActive {
            (data, _) = try await cloud.send(req)
        } else {
            let (d, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: d, encoding: .utf8) ?? ""
                Log.claude.error("Claude HTTP \(http.statusCode): \(text.prefix(500))")
                throw NaviError.http(status: http.statusCode, body: text)
            }
            data = d
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw NaviError.decoding("Claude response missing content")
        }
        let usage = json["usage"] as? [String: Any]
        let msg = Message(id: json["id"] as? String ?? "",
                          stopReason: json["stop_reason"] as? String,
                          content: content,
                          inputTokens: usage?["input_tokens"] as? Int ?? 0,
                          outputTokens: usage?["output_tokens"] as? Int ?? 0)
        await MainActor.run {
            NaviSettings.shared.usageClaudeInputTokens += msg.inputTokens
            NaviSettings.shared.usageClaudeOutputTokens += msg.outputTokens
        }
        return msg
    }

    /// Convenience: single-shot text completion (no tools, no streaming).
    func complete(model: String, system: String?, prompt: String, maxTokens: Int = 2048, effort: String = "low") async throws -> String {
        let m = try await create(model: model, system: system,
                                 messages: [["role": "user", "content": prompt]],
                                 maxTokens: maxTokens, effort: effort)
        return m.text
    }

    /// Vision helper: describe/summarize an image (JPEG/PNG data) with a prompt.
    func describeImage(model: String, prompt: String, imageData: Data, mediaType: String = "image/jpeg",
                       system: String? = nil, maxTokens: Int = 1024) async throws -> String {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": imageData.base64EncodedString()]],
            ["type": "text", "text": prompt],
        ]
        let m = try await create(model: model, system: system,
                                 messages: [["role": "user", "content": content]],
                                 maxTokens: maxTokens, effort: "low", thinking: nil)
        return m.text
    }
}
