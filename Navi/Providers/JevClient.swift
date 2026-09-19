import Foundation

/// Client for TypeSafe AI's System One API (model: Jev).
///
/// Jev does not generate text. You send `state` (any text, ideally structured)
/// plus a dictionary of typed questions and get back typed answers with
/// calibrated probabilities and a confidence score, in ~70–500 ms.
///
///   POST https://api.typesafe.ai/v1/systemone
///   Authorization: Bearer <TYPESAFE_API_KEY>
///   { "state": "...", "model": "jev-latest", "questions": { name: Question } }
///
/// Question types:
///   choice — pick one of `criteria` {key: description}   → choice, probabilities, confidence
///   score  — rate on ordered `criteria` [level0, level1…] → score (float), legend, confidence
///   noul   — is the statement true?                        → noul (probability 0–1)
///
/// Docs: https://docs.typesafe.ai  (full text mirrored in docs/jev-docs-full.txt)
final class JevClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private let session: URLSession
    private let cache = ResponseCache()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "Navi/0.1 (macOS)"]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Question / answer types

    enum Question: Encodable, Sendable {
        case choice(instructions: String, criteria: [String: String])
        case score(instructions: String, criteria: [String])
        case noul(instructions: String)

        private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .choice(let i, let crit):
                try c.encode("choice", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(crit, forKey: .criteria)
            case .score(let i, let crit):
                try c.encode("score", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(crit, forKey: .criteria)
            case .noul(let i):
                try c.encode("noul", forKey: .type); try c.encode(i, forKey: .instructions)
            }
        }
    }

    enum Answer: Sendable {
        case choice(choice: String, probabilities: [String: Double], confidence: Double)
        case score(score: Double, legend: [String: String], confidence: Double)
        case noul(Double)

        var confidence: Double {
            switch self {
            case .choice(_, _, let c), .score(_, _, let c): return c
            case .noul(let p): return abs(p - 0.5) * 2   // distance from coin-flip
            }
        }
        var choice: String? { if case .choice(let c, _, _) = self { return c }; return nil }
        var probabilities: [String: Double]? { if case .choice(_, let p, _) = self { return p }; return nil }
        var score: Double? { if case .score(let s, _, _) = self { return s }; return nil }
        var noul: Double? { if case .noul(let n) = self { return n }; return nil }
        var isTrue: Bool { (noul ?? 0) >= 0.5 }
    }

    struct Response: Sendable {
        var model: String
        var answers: [String: Answer]
        var inputTokens: Int
        var outputTokens: Int
        var latencyMs: Int
        subscript(_ key: String) -> Answer? { answers[key] }
    }

    // MARK: - Call

    var isConfigured: Bool { Keychain.has(.typesafe) }

    /// Ask Jev one or more questions about `state`. Throws `NaviError`.
    func ask(state: String, questions: [String: Question], model: String? = nil,
             cacheable: Bool = true) async throws -> Response {
        guard let key = Keychain.get(.typesafe), !key.isEmpty else { throw NaviError.missingAPIKey(.typesafe) }
        let settingsModel = await MainActor.run { NaviSettings.shared.jevModel }
        let model = model ?? settingsModel

        let body = RequestBody(state: state, model: model, questions: questions)
        let data = try JSONEncoder().encode(body)
        if cacheable, let hit = await cache.get(data) { return hit }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let start = Date()
        let (respData, resp) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Jev") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: respData, encoding: .utf8) ?? ""
            Log.jev.error("Jev HTTP \(http.statusCode): \(text)")
            throw NaviError.http(status: http.statusCode, body: text)
        }
        let parsed = try Self.parse(respData, latencyMs: ms)
        Log.jev.debug("Jev \(parsed.answers.count) answers in \(ms)ms (\(parsed.inputTokens) in)")
        await MainActor.run { NaviSettings.shared.usageJevCalls += 1 }
        if cacheable { await cache.set(data, parsed) }
        return parsed
    }

    /// Lists models available to this key (`GET /v1/models`), for the settings screen.
    func listModels() async throws -> [String] {
        guard let key = Keychain.get(.typesafe) else { throw NaviError.missingAPIKey(.typesafe) }
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NaviError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (json?["models"] as? [[String: Any]]) ?? (json?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { $0["id"] as? String ?? $0["name"] as? String }
    }

    // MARK: - Internals

    private struct RequestBody: Encodable {
        var state: String
        var model: String
        var questions: [String: Question]
    }

    static func parse(_ data: Data, latencyMs: Int) throws -> Response {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answersJSON = json["answers"] as? [String: [String: Any]] else {
            throw NaviError.decoding("Jev response missing 'answers': \(String(data: data, encoding: .utf8) ?? "")")
        }
        var answers: [String: Answer] = [:]
        for (name, a) in answersJSON {
            switch a["type"] as? String {
            case "choice":
                let probs = (a["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
                answers[name] = .choice(choice: a["choice"] as? String ?? "",
                                        probabilities: probs,
                                        confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0)
            case "score":
                let legend = (a["legend"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
                answers[name] = .score(score: (a["score"] as? NSNumber)?.doubleValue ?? 0,
                                       legend: legend,
                                       confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0)
            case "noul":
                answers[name] = .noul((a["noul"] as? NSNumber)?.doubleValue ?? 0)
            default:
                continue
            }
        }
        let usage = json["usage"] as? [String: Any]
        return Response(model: json["model"] as? String ?? "",
                        answers: answers,
                        inputTokens: (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0,
                        outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0,
                        latencyMs: latencyMs)
    }

    /// Small LRU so retyping the same query doesn't re-bill.
    private actor ResponseCache {
        private var store: [Data: (Response, Date)] = [:]
        private let ttl: TimeInterval = 120
        func get(_ k: Data) -> Response? {
            guard let (r, t) = store[k], Date().timeIntervalSince(t) < ttl else { return nil }
            return r
        }
        func set(_ k: Data, _ r: Response) {
            if store.count > 200 { store.removeAll() }
            store[k] = (r, Date())
        }
    }
}
