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
///
/// Second transport — **Vercel AI Gateway** (model `typesafe-ai/jev`). Vercel
/// documents it as "AI SDK only", so the wire shape below is taken from
/// `@ai-sdk/gateway` 4.0.87 (`GatewayEvaluationModel`):
///
///   POST https://ai-gateway.vercel.sh/v4/ai/evaluation-model
///   Authorization: Bearer <AI_GATEWAY_API_KEY>
///   ai-model-id: typesafe-ai/jev
///   ai-evaluation-model-specification-version: 4
///   ai-gateway-protocol-version: 0.0.1
///   ai-gateway-auth-method: api-key
///   { "state": …, "questions": { name: {type: choice|score|boolean, instructions, criteria} } }
///
/// Same schema as TypeSafe's except `noul` is spelled `boolean` and comes
/// back as `{type:"boolean", probability}`; per-answer `confidence` is not
/// guaranteed (it may arrive under `providerMetadata.typesafe`), so when it is
/// absent we derive it from the probability distribution.
final class JevClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let vercelEndpoint = URL(string: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model")!
    static let vercelModel = "typesafe-ai/jev"

    enum Transport: String, Sendable { case typesafe, vercelGateway }

    /// Picks the transport for a preference, or nil when no usable key exists.
    static func resolveTransport(preference: JevProvider) -> Transport? {
        switch preference {
        case .typesafe: return Keychain.has(.typesafe) ? .typesafe : nil
        case .vercelGateway: return Keychain.has(.vercelGateway) ? .vercelGateway : nil
        case .auto:
            if Keychain.has(.typesafe) { return .typesafe }
            if Keychain.has(.vercelGateway) { return .vercelGateway }
            return nil
        }
    }

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

        /// Set on the encoder's userInfo to spell yes/no questions `boolean` (Vercel).
        static let booleanSpellingKey = CodingUserInfoKey(rawValue: "jev.booleanSpelling")!

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .choice(let i, let crit):
                try c.encode("choice", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(crit, forKey: .criteria)
            case .score(let i, let crit):
                try c.encode("score", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(crit, forKey: .criteria)
            case .noul(let i):
                let spelling = encoder.userInfo[Self.booleanSpellingKey] as? String ?? "noul"
                try c.encode(spelling, forKey: .type); try c.encode(i, forKey: .instructions)
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
        var transport: Transport = .typesafe
        subscript(_ key: String) -> Answer? { answers[key] }
    }

    // MARK: - Call

    /// True when a key exists for the transport selected in Settings.
    var isConfigured: Bool { activeTransport != nil }

    /// The transport that `ask` will use, honouring `NaviSettings.jevProvider`.
    var activeTransport: Transport? { Self.resolveTransport(preference: Self.preference) }

    /// Thread-safe read of the Settings preference (callers run off the main actor).
    private static var preference: JevProvider {
        JevProvider(rawValue: UserDefaults.standard.string(forKey: "jevProvider") ?? "") ?? .auto
    }

    /// Ask Jev one or more questions about `state`. Throws `NaviError`.
    /// `transport` overrides the Settings preference (used by the connection tests).
    func ask(state: String, questions: [String: Question], model: String? = nil,
             cacheable: Bool = true, transport: Transport? = nil) async throws -> Response {
        let pref = Self.preference
        guard let transport = transport ?? Self.resolveTransport(preference: pref) else {
            throw NaviError.missingAPIKey(pref == .vercelGateway ? .vercelGateway : .typesafe)
        }
        let settingsModel = await MainActor.run { NaviSettings.shared.jevModel }
        let (req, cacheKey) = try Self.buildRequest(transport: transport, state: state, questions: questions,
                                                    model: model ?? settingsModel)
        if cacheable, let hit = await cache.get(cacheKey) { return hit }

        let start = Date()
        let (respData, resp) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Jev") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: respData, encoding: .utf8) ?? ""
            Log.jev.error("Jev (\(transport.rawValue)) HTTP \(http.statusCode): \(text)")
            throw NaviError.http(status: http.statusCode, body: text)
        }
        var parsed = try transport == .typesafe ? Self.parse(respData, latencyMs: ms) : Self.parseVercel(respData, latencyMs: ms)
        parsed.transport = transport
        Log.jev.debug("Jev/\(transport.rawValue) \(parsed.answers.count) answers in \(ms)ms (\(parsed.inputTokens) in)")
        await MainActor.run { NaviSettings.shared.usageJevCalls += 1 }
        if cacheable { await cache.set(cacheKey, parsed) }
        return parsed
    }

    /// Builds the HTTP request for a transport. Returns the request and a cache key
    /// (the transport-tagged body).
    static func buildRequest(transport: Transport, state: String, questions: [String: Question],
                             model: String) throws -> (URLRequest, Data) {
        switch transport {
        case .typesafe:
            guard let key = Keychain.get(.typesafe), !key.isEmpty else { throw NaviError.missingAPIKey(.typesafe) }
            let data = try JSONEncoder().encode(RequestBody(state: state, model: model, questions: questions))
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            return (req, Data("ts:".utf8) + data)
        case .vercelGateway:
            guard let key = Keychain.get(.vercelGateway), !key.isEmpty else { throw NaviError.missingAPIKey(.vercelGateway) }
            let enc = JSONEncoder()
            enc.userInfo[Question.booleanSpellingKey] = "boolean"
            let data = try enc.encode(VercelRequestBody(state: state, questions: questions))
            // Gateway model ids are namespaced ("typesafe-ai/jev"); a bare TypeSafe id maps to the default.
            let gatewayModel = model.contains("/") ? model : vercelModel
            var req = URLRequest(url: vercelEndpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(gatewayModel, forHTTPHeaderField: "ai-model-id")
            req.setValue("4", forHTTPHeaderField: "ai-evaluation-model-specification-version")
            req.setValue("0.0.1", forHTTPHeaderField: "ai-gateway-protocol-version")
            req.setValue("api-key", forHTTPHeaderField: "ai-gateway-auth-method")
            req.httpBody = data
            return (req, Data("vc:\(gatewayModel):".utf8) + data)
        }
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

    private struct VercelRequestBody: Encodable {
        var state: String
        var questions: [String: Question]
    }

    /// Parses a Vercel AI Gateway `evaluation-model` response into `Response`.
    static func parseVercel(_ data: Data, latencyMs: Int) throws -> Response {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answersJSON = json["answers"] as? [String: [String: Any]] else {
            throw NaviError.decoding("Vercel Gateway response missing 'answers': \(String(data: data, encoding: .utf8) ?? "")")
        }
        // Optional per-question confidence, if the gateway surfaces TypeSafe metadata.
        let meta = (json["providerMetadata"] as? [String: Any])?["typesafe"] as? [String: Any]
        let confidences = meta?["confidence"] as? [String: Any]
        func confidence(for name: String, fallback: Double) -> Double {
            if let c = (confidences?[name] as? NSNumber)?.doubleValue { return c }
            if let c = ((meta?[name] as? [String: Any])?["confidence"] as? NSNumber)?.doubleValue { return c }
            return fallback
        }
        var answers: [String: Answer] = [:]
        for (name, a) in answersJSON {
            switch a["type"] as? String {
            case "choice":
                let probs = (a["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
                answers[name] = .choice(choice: a["choice"] as? String ?? "",
                                        probabilities: probs,
                                        confidence: confidence(for: name, fallback: derivedConfidence(probs)))
            case "score":
                let probs = (a["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
                answers[name] = .score(score: (a["score"] as? NSNumber)?.doubleValue ?? 0,
                                       legend: [:],
                                       confidence: confidence(for: name, fallback: derivedConfidence(probs)))
            case "boolean", "noul":
                let p = (a["probability"] as? NSNumber)?.doubleValue ?? (a["noul"] as? NSNumber)?.doubleValue ?? 0
                answers[name] = .noul(p)
            default:
                continue
            }
        }
        let usage = json["usage"] as? [String: Any]
        return Response(model: vercelModel,
                        answers: answers,
                        inputTokens: (usage?["inputTokens"] as? NSNumber)?.intValue ?? 0,
                        outputTokens: (usage?["outputTokens"] as? NSNumber)?.intValue ?? 0,
                        latencyMs: latencyMs,
                        transport: .vercelGateway)
    }

    /// Confidence proxy when the API doesn't send one: how far the top option
    /// stands above the runner-up (1.0 = certain, 0.0 = tie).
    static func derivedConfidence(_ probs: [String: Double]) -> Double {
        let sorted = probs.values.sorted(by: >)
        guard let top = sorted.first else { return 0 }
        let second = sorted.dropFirst().first ?? 0
        return max(0, min(1, top - second))
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
