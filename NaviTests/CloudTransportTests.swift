import Testing
import Foundation
@testable import Navi

// MARK: - HTTP stub

/// In-process HTTP stub keyed by host, so parallel tests never share a handler.
/// Each test picks a unique base URL (`http://<name>.test`) and registers a handler for it.
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body: Data }
    typealias Handler = @Sendable (URLRequest) -> Reply

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func install(host: String, _ handler: @escaping Handler) {
        lock.lock(); handlers[host] = handler; seen[host] = []; lock.unlock()
    }
    static func requests(host: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen[host] ?? [] }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock(); defer { lock.unlock() }
        return handlers[host] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.lock()
        let handler = Self.handlers[host]
        // URLSession moves the body into a stream; read it back so handlers can inspect it.
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536); defer { buf.deallocate() }
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 65536); if n <= 0 { break }; data.append(buf, count: n) }
            req.httpBody = data
        }
        Self.seen[host, default: []].append(req)
        Self.lock.unlock()
        guard let handler else { return }
        let reply = handler(req)
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func json(_ status: Int, _ obj: Any) -> Reply {
        Reply(status: status, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: obj))
    }
}

private func transport(host: String, tokens: MemoryTokenStore = MemoryTokenStore(access: "acc-1", refresh: "ref-1")) -> CloudTransport {
    CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
}

private func bodyJSON(_ req: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

// MARK: - /v1/me contract

struct EntitlementsTests {
    static let meJSON = """
    { "user": {"id": "u_123", "email": "liam@example.com"},
      "tier": "pro_recall",
      "trialEndsAt": "2026-09-29T12:00:00Z",
      "entitlements": {"answers": true, "tasks": true, "voice": true, "recall": true},
      "quotas": {"tasksPerMonth": 300},
      "usage": {"answersToday": 12, "tasksToday": 2, "tasksThisMonth": 41, "resetsAt": "2026-09-23T00:00:00.000Z"} }
    """

    @Test func decodesTheContract() throws {
        let me = try AccountInfo.decode(Data(Self.meJSON.utf8))
        #expect(me.user.email == "liam@example.com")
        #expect(me.tier == .proRecall)
        #expect(me.entitlements == .all)
        #expect(me.quotas.answersPerDay == nil && me.quotas.tasksPerMonth == 300)
        #expect(me.usage.answersToday == 12 && me.usage.tasksThisMonth == 41)
        #expect(me.usage.resetsAt == LenientDate.parse("2026-09-23T00:00:00Z"))      // fractional seconds accepted
        #expect(me.trialEndsAt == LenientDate.parse("2026-09-29T12:00:00Z"))
        #expect(me.trialDaysLeft(now: LenientDate.parse("2026-09-22T12:00:00Z")!) == 7)
        #expect(me.trialDaysLeft(now: LenientDate.parse("2026-10-01T12:00:00Z")!) == nil)
    }

    @Test func freeTierAndMissingFlags() throws {
        let json = """
        {"user":{"id":"u","email":"a@b.c"},"tier":"free","entitlements":{"answers":true},"quotas":{"answersPerDay":20,"tasksPerDay":5},"usage":{"answersToday":3,"resetsAt":1790000000}}
        """
        let me = try AccountInfo.decode(Data(json.utf8))
        #expect(me.tier == .free)
        #expect(me.entitlements.answers && !me.entitlements.recall && !me.entitlements.voice)   // missing ⇒ false
        #expect(me.quotas.answersPerDay == 20)
        #expect(me.usage.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))                // epoch seconds accepted
        #expect(me.trialEndsAt == nil)
        // Round-trips through the UserDefaults snapshot.
        let again = try AccountInfo.decode(JSONEncoder().encode(me))
        #expect(again == me)
    }

    @Test func entitlementsGateFeatures() {
        let pro = Entitlements(answers: true, tasks: true, voice: true, recall: false)
        #expect(pro.allows(.answer) && pro.allows(.task) && pro.allows(.route))
        #expect(!pro.allows(.recallDigest) && !pro.allows(.recallTriage))
        #expect(Entitlements.none.allows(.route))
    }
}

// MARK: - Request building

struct CloudRequestTests {
    @Test func jevRequestGoesToTheProxyWithFeatureAndRun() throws {
        let cloud = transport(host: "jev-build.test")
        let jev = JevClient(cloud: cloud)
        #expect(jev.activeTransport == .navi)
        #expect(jev.isConfigured)                        // no vendor key needed
        let run = CloudRun(feature: .route, runID: UUID())
        let (req, key) = try jev.buildNaviRequest(state: .string("s"), questions: ["ok": .noul(instructions: "x")],
                                                  model: "jev-latest", run: run)
        #expect(req.url?.absoluteString == "http://jev-build.test/v1/jev")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "X-Navi-Feature") == "route")
        #expect(req.value(forHTTPHeaderField: "X-Navi-Run") == run.runID.uuidString.lowercased())
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)   // attached on send
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "jev-latest")                // exact TypeSafe body
        #expect(((body["questions"] as? [String: [String: Any]])?["ok"]?["type"] as? String) == "noul")
        #expect(String(data: key.prefix(5), encoding: .utf8) == "navi:")
    }

    @Test func claudeRequestKeepsAnthropicVersionAndPicksThePath() throws {
        let cloud = transport(host: "claude-build.test")
        let claude = ClaudeClient(cloud: cloud)
        #expect(claude.isConfigured)
        let req = try claude.request(body: ["model": "claude-sonnet-5", "messages": []], fallbackFeature: .answer)
        #expect(req.url?.path == "/v1/claude")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == ClaudeClient.apiVersion)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Navi-Feature") == "answer")
        #expect(req.value(forHTTPHeaderField: "X-Navi-Run") != nil)
        let digest = try claude.request(body: ["model": "claude-haiku-4-5"], fallbackFeature: .recallDigest)
        #expect(digest.url?.path == "/v1/digest")
        #expect(digest.value(forHTTPHeaderField: "X-Navi-Feature") == "recall_digest")
    }

    @Test func signedOutFallsBackToVendorKeys() {
        let cloud = transport(host: "byok.test", tokens: MemoryTokenStore())
        #expect(!cloud.isActive)
        let claude = ClaudeClient(cloud: cloud)
        unsetenv("ANTHROPIC_API_KEY")
        // Configured only if this Mac's Keychain has a key — either way, not via the cloud.
        #expect(claude.isConfigured == Keychain.has(.anthropic))
        #expect(JevClient(cloud: cloud).activeTransport != .navi)
    }

    @Test func runScopeRidesIntoTheRequest() async throws {
        let host = "jev-scope.test"
        StubProtocol.install(host: host) { _ in
            StubProtocol.json(200, ["model": "jev-latest", "answers": ["ok": ["type": "noul", "noul": 0.9]], "usage": ["input_tokens": 1, "output_tokens": 1]])
        }
        let jev = JevClient(cloud: transport(host: host))
        let id = UUID()
        let r = try await CloudRun.$current.withValue(CloudRun(feature: .task, runID: id)) {
            try await jev.ask(state: "s", questions: ["ok": .noul(instructions: "x")], cacheable: false)
        }
        #expect(r["ok"]?.isTrue == true && r.transport == .navi)
        let sent = StubProtocol.requests(host: host)
        #expect(sent.count == 1)
        #expect(sent.first?.value(forHTTPHeaderField: "X-Navi-Run") == id.uuidString.lowercased())
        #expect(sent.first?.value(forHTTPHeaderField: "X-Navi-Feature") == "task")
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer acc-1")
    }

    @Test func oneRunPerQueryAndInheritedByChildTasks() async {
        #expect(QueryContext.empty.runID != QueryContext.empty.runID)
        let run = CloudRun(feature: .answer)
        let inherited = await CloudRun.$current.withValue(run) {
            await Task { CloudRun.current }.value          // `Task {}` inherits task-locals
        }
        #expect(inherited == run)
        #expect(CloudRun.current == nil)
        #expect(CloudRun.resolve(fallback: .route).feature == .route)
    }
}

// MARK: - Error mapping and session refresh

struct CloudErrorTests {
    @Test func maps402ToQuotaExceeded() async {
        let host = "quota.test"
        StubProtocol.install(host: host) { _ in
            StubProtocol.json(402, ["error": "quota_exceeded", "feature": "answer", "tier": "free", "resetsAt": "2026-09-23T00:00:00Z"])
        }
        let cloud = transport(host: host)
        do {
            _ = try await cloud.send(cloud.get(path: "/v1/me"))
            Issue.record("expected quotaExceeded")
        } catch NaviError.quotaExceeded(let feature, let tier, let resetsAt) {
            #expect(feature == "answer" && tier == "free")
            #expect(resetsAt == LenientDate.parse("2026-09-23T00:00:00Z"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func maps403ToNotEntitled() async {
        let host = "entitle.test"
        StubProtocol.install(host: host) { _ in
            StubProtocol.json(403, ["error": "not_entitled", "feature": "recall_digest", "tier": "pro"])
        }
        let cloud = transport(host: host)
        let gemini = GeminiClient(cloud: cloud)
        do {
            _ = try await gemini.generate(prompt: "x")
            Issue.record("expected notEntitled")
        } catch NaviError.notEntitled(let feature, let tier) {
            #expect(feature == "recall_digest" && tier == "pro")
        } catch {
            Issue.record("wrong error: \(error)")
        }
        let sent = StubProtocol.requests(host: host)
        #expect(sent.first?.url?.path == "/v1/digest")
        #expect(bodyJSON(sent.first!)["model"] as? String == GeminiClient.defaultModel)
    }

    @Test func refreshesOnceOn401AndRetriesWithTheNewToken() async throws {
        let host = "refresh.test"
        StubProtocol.install(host: host) { req in
            switch req.url!.path {
            case "/auth/refresh":
                #expect(bodyJSON(req)["refreshToken"] as? String == "ref-1")
                return StubProtocol.json(200, ["accessToken": "acc-2", "refreshToken": "ref-2", "expiresAt": "2026-09-22T13:00:00Z"])
            case "/v1/me":
                if req.value(forHTTPHeaderField: "Authorization") == "Bearer acc-2" {
                    return StubProtocol.json(200, ["user": ["id": "u", "email": "a@b.c"], "tier": "pro",
                                                   "entitlements": ["answers": true, "tasks": true, "voice": true],
                                                   "quotas": [:], "usage": [:]])
                }
                return StubProtocol.json(401, ["error": "unauthenticated"])
            default:
                return StubProtocol.json(404, [:])
            }
        }
        let tokens = MemoryTokenStore(access: "acc-1", refresh: "ref-1")
        let cloud = transport(host: host, tokens: tokens)
        let me = try await cloud.me()
        #expect(me.tier == .pro)
        #expect(tokens.accessToken == "acc-2" && tokens.refreshToken == "ref-2")
        #expect(tokens.accessExpiresAt == LenientDate.parse("2026-09-22T13:00:00Z"))
        let paths = StubProtocol.requests(host: host).map { $0.url!.path }
        #expect(paths == ["/v1/me", "/auth/refresh", "/v1/me"])
    }

    @Test func failedRefreshSignsOut() async {
        let host = "signout.test"
        StubProtocol.install(host: host) { req in
            req.url!.path == "/auth/refresh" ? StubProtocol.json(401, ["error": "invalid_grant"]) : StubProtocol.json(401, ["error": "unauthenticated"])
        }
        let tokens = MemoryTokenStore(access: "acc-1", refresh: "ref-1")
        let cloud = transport(host: host, tokens: tokens)
        do {
            _ = try await cloud.me()
            Issue.record("expected signedOut")
        } catch NaviError.signedOut {
            #expect(tokens.accessToken == nil && tokens.refreshToken == nil)
            #expect(!cloud.isSignedIn)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func streamsSSEThroughTheProxy() async throws {
        let host = "sse.test"
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}

        event: message_delta
        data: {"type":"message_delta","usage":{"output_tokens":2}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        StubProtocol.install(host: host) { req in
            #expect(bodyJSON(req)["stream"] as? Bool == true)
            return StubProtocol.Reply(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8))
        }
        let claude = ClaudeClient(cloud: transport(host: host))
        var text = ""
        for try await chunk in claude.stream(model: "claude-sonnet-5", system: nil, messages: [["role": "user", "content": "hi"]]) {
            text += chunk
        }
        #expect(text == "Hello")
        let sent = StubProtocol.requests(host: host).first
        #expect(sent?.url?.path == "/v1/claude")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer acc-1")
        #expect(sent?.value(forHTTPHeaderField: "X-Navi-Feature") == "answer")
    }

    @Test func exchangeStoresTokens() async throws {
        let host = "exchange.test"
        StubProtocol.install(host: host) { req in
            #expect(req.url!.path == "/auth/exchange" && bodyJSON(req)["code"] as? String == "abc")
            return StubProtocol.json(200, ["accessToken": "acc-x", "refreshToken": "ref-x", "expiresAt": "2026-09-22T13:00:00Z"])
        }
        let tokens = MemoryTokenStore()
        let cloud = transport(host: host, tokens: tokens)
        #expect(!cloud.isActive)
        try await cloud.exchange(code: "abc")
        #expect(cloud.isActive && tokens.accessToken == "acc-x" && tokens.refreshToken == "ref-x")
    }
}

// MARK: - Panel wording

struct AccountErrorPresentationTests {
    @Test func quotaLineNamesTheCapAndPlan() {
        let p = PanelViewModel.accountPresentation(for: NaviError.quotaExceeded(feature: "answer", tier: "free", resetsAt: nil),
                                                   quotas: Quotas(answersPerDay: 20, tasksPerDay: 5))
        #expect(p?.message == "You've used today's 20 answers on the Free plan.")
        #expect(p?.actionTitle == "Upgrade")
        let t = PanelViewModel.accountPresentation(for: NaviError.quotaExceeded(feature: "task", tier: "free", resetsAt: nil),
                                                   quotas: Quotas(answersPerDay: 20, tasksPerDay: 5))
        #expect(t?.message == "You've used today's 5 tasks on the Free plan.")
        let m = PanelViewModel.accountPresentation(for: NaviError.quotaExceeded(feature: "task", tier: "pro", resetsAt: nil),
                                                   quotas: Quotas(tasksPerMonth: 300))
        #expect(m?.message == "You've used this month's 300 tasks on the Pro plan.")
    }

    @Test func entitlementAndSignedOutLines() {
        let r = PanelViewModel.accountPresentation(for: NaviError.notEntitled(feature: "recall_digest", tier: "pro"), quotas: Quotas())
        #expect(r?.actionTitle == "Add Recall")
        #expect(r?.message.hasPrefix("Recall isn't included in the Pro plan") == true)
        let s = PanelViewModel.accountPresentation(for: NaviError.signedOut, quotas: Quotas())
        #expect(s?.message == "Sign in to Navi to keep going." && s?.actionTitle == "Sign in")
        #expect(PanelViewModel.accountPresentation(for: NaviError.other("boom"), quotas: Quotas()) == nil)
        #expect(NaviError.quotaExceeded(feature: "answer", tier: "free", resetsAt: nil).isAccountError)
        #expect(!NaviError.cancelled.isAccountError)
    }
}
