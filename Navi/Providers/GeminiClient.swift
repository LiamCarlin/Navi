import Foundation

/// Minimal client for the Gemini `generateContent` REST API. Used only by the
/// screen-memory digester because Flash-Lite is the cheapest multimodal model
/// that reliably returns strict JSON.
///
///   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
///   x-goog-api-key: <GEMINI_API_KEY>
///   { "contents": [{ "parts": [{ "text": … }, { "inline_data": { "mime_type", "data" } }] }],
///     "generationConfig": { "responseMimeType": "application/json" } }
///
/// The key is sent as a header rather than the `?key=` query parameter so it
/// never lands in proxy/URL logs; both forms are accepted by the API.
final class GeminiClient: @unchecked Sendable {
    static let defaultModel = "gemini-2.5-flash-lite"
    static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!

    struct Usage: Sendable {
        var promptTokens: Int
        var outputTokens: Int
    }

    struct Reply: Sendable {
        var text: String
        var usage: Usage
        var finishReason: String?
    }

    /// An inline image part (JPEG/PNG/WebP bytes).
    struct ImagePart: Sendable {
        var data: Data
        var mimeType: String = "image/jpeg"
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.httpAdditionalHeaders = ["User-Agent": "Navi/0.1 (macOS)"]
        session = URLSession(configuration: cfg)
    }

    var isConfigured: Bool { Keychain.has(.gemini) }

    /// One-shot generation. When `jsonMode` is true the model is constrained to
    /// emit `application/json`, which removes the usual code-fence noise.
    func generate(model: String = GeminiClient.defaultModel,
                  system: String? = nil,
                  prompt: String,
                  images: [ImagePart] = [],
                  jsonMode: Bool = true,
                  maxOutputTokens: Int = 1024,
                  temperature: Double = 0.2) async throws -> Reply {
        guard let key = Keychain.get(.gemini), !key.isEmpty else { throw NaviError.missingAPIKey(.gemini) }

        var parts: [[String: Any]] = [["text": prompt]]
        for img in images {
            parts.append(["inline_data": ["mime_type": img.mimeType, "data": img.data.base64EncodedString()]])
        }
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "maxOutputTokens": maxOutputTokens,
                "temperature": temperature,
            ] as [String: Any],
        ]
        if jsonMode {
            var gc = body["generationConfig"] as! [String: Any]
            gc["responseMimeType"] = "application/json"
            body["generationConfig"] = gc
        }
        if let system, !system.isEmpty {
            body["system_instruction"] = ["parts": [["text": system]]]
        }

        var req = URLRequest(url: Self.baseURL.appendingPathComponent("\(model):generateContent"))
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Gemini") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            Log.memory.error("Gemini HTTP \(http.statusCode): \(text.prefix(300))")
            throw NaviError.http(status: http.statusCode, body: text)
        }
        return try Self.parse(data)
    }

    /// Parses `candidates[0].content.parts[*].text` and `usageMetadata`.
    static func parse(_ data: Data) throws -> Reply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NaviError.decoding("Gemini response is not a JSON object")
        }
        if let err = json["error"] as? [String: Any] {
            throw NaviError.other("Gemini error: \(err["message"] as? String ?? "unknown")")
        }
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
            let block = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw NaviError.decoding("Gemini response has no candidates\(block.map { " (blocked: \($0))" } ?? "")")
        }
        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let usage = json["usageMetadata"] as? [String: Any]
        return Reply(text: text,
                     usage: Usage(promptTokens: (usage?["promptTokenCount"] as? NSNumber)?.intValue ?? 0,
                                  outputTokens: (usage?["candidatesTokenCount"] as? NSNumber)?.intValue ?? 0),
                     finishReason: first["finishReason"] as? String)
    }
}
