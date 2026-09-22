import Foundation

// MARK: - Features and runs

/// What a cloud call is for. Sent as `X-Navi-Feature`; the meter counts usage
/// per (feature, run) and the tier decides which features are allowed.
enum CloudFeature: String, Sendable, CaseIterable {
    case route
    case answer
    case task
    case voice
    case recallTriage = "recall_triage"
    case recallDigest = "recall_digest"

    /// The proxy path this feature's model calls go to. Digest traffic (Claude
    /// Haiku or Gemini) is a separate, `recall`-gated route.
    var claudePath: String { self == .recallDigest ? "/v1/digest" : "/v1/claude" }

    /// Human noun for quota messages ("answers", "tasks").
    var unitNoun: String {
        switch self {
        case .route, .answer: return "answers"
        case .task, .voice: return "tasks"
        case .recallTriage, .recallDigest: return "Recall"
        }
    }
}

/// The run a cloud call belongs to: one per answer, per agent task, per voice
/// command, per memory frame. Set with `CloudRun.$current.withValue(...)` at
/// the entry point; every `Task {}` created inside inherits it (detached
/// tasks do not — set it again there). Clients fall back to a fresh run with
/// their default feature when nothing is set.
struct CloudRun: Sendable, Equatable {
    var feature: CloudFeature
    var runID: UUID

    init(feature: CloudFeature, runID: UUID = UUID()) {
        self.feature = feature; self.runID = runID
    }

    @TaskLocal static var current: CloudRun?

    /// The run in scope, or a fresh one for `fallback`.
    static func resolve(fallback: CloudFeature) -> CloudRun {
        current ?? CloudRun(feature: fallback)
    }
}

// MARK: - Token storage

/// Where the account session lives. Keychain in the app; memory in tests.
protocol CloudTokenStore: AnyObject, Sendable {
    var accessToken: String? { get }
    var refreshToken: String? { get }
    var accessExpiresAt: Date? { get }
    func store(access: String, refresh: String?, expiresAt: Date?)
    func clear()
}

/// Tokens ride in the same single Keychain item as the API keys (one ACL
/// prompt); the expiry is not secret and lives in UserDefaults.
final class KeychainTokenStore: CloudTokenStore, @unchecked Sendable {
    static let expiresKey = "naviAccessExpiresAt"
    var accessToken: String? { Keychain.get(.naviAccess) }
    var refreshToken: String? { Keychain.get(.naviRefresh) }
    var accessExpiresAt: Date? {
        let t = UserDefaults.standard.double(forKey: Self.expiresKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func store(access: String, refresh: String?, expiresAt: Date?) {
        Keychain.set(.naviAccess, value: access)
        if let refresh { Keychain.set(.naviRefresh, value: refresh) }
        UserDefaults.standard.set(expiresAt?.timeIntervalSince1970 ?? 0, forKey: Self.expiresKey)
    }
    func clear() {
        Keychain.set(.naviAccess, value: nil)
        Keychain.set(.naviRefresh, value: nil)
        UserDefaults.standard.removeObject(forKey: Self.expiresKey)
    }
}

final class MemoryTokenStore: CloudTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var access: String?, refresh: String?, expires: Date?
    init(access: String? = nil, refresh: String? = nil, expiresAt: Date? = nil) {
        self.access = access; self.refresh = refresh; self.expires = expiresAt
    }
    var accessToken: String? { lock.withLock { access } }
    var refreshToken: String? { lock.withLock { refresh } }
    var accessExpiresAt: Date? { lock.withLock { expires } }
    func store(access: String, refresh: String?, expiresAt: Date?) {
        lock.withLock { self.access = access; if let refresh { self.refresh = refresh }; self.expires = expiresAt }
    }
    func clear() { lock.withLock { access = nil; refresh = nil; expires = nil } }
}

// MARK: - Transport

/// The Navi Cloud transport (docs/LAUNCH_ROADMAP.md §3.1).
///
/// `JevClient`, `ClaudeClient` and `GeminiClient` route through here when the
/// user is signed in (`isActive`): same request bodies as the vendors, sent to
/// `https://api.navi.app/v1/{jev,claude,digest}` with the account's bearer
/// token plus `X-Navi-Feature` / `X-Navi-Run`. Otherwise they keep talking to
/// the vendors with the developer's own keys.
///
/// Errors: 401 → refresh the session once and retry; a second 401 (or a failed
/// refresh) signs the account out and throws `NaviError.signedOut`. 402/403
/// decode `{error, feature, tier, resetsAt}` into `.quotaExceeded` / `.notEntitled`.
final class CloudTransport: @unchecked Sendable {
    static let shared = CloudTransport()

    static let defaultBaseURL = "https://api.navi.app"
    static let baseURLKey = "cloudBaseURL"
    static let useCloudKey = "useCloud"

    let session: URLSession
    let tokens: CloudTokenStore
    private let baseURLOverride: URL?
    private let refresher = Refresher()
    private let lastUse = LastUse()

    init(session: URLSession? = nil, baseURL: URL? = nil, tokens: CloudTokenStore = KeychainTokenStore()) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600     // streaming answers and agent turns
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = ["User-Agent": "Navi/\(Self.appVersion) (macOS)"]
            self.session = URLSession(configuration: cfg)
        }
        self.baseURLOverride = baseURL
        self.tokens = tokens
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    // MARK: Selection

    /// `NaviSettings.cloudBaseURL`, read off the main actor. `defaults write
    /// com.liamcarlin.navi cloudBaseURL http://127.0.0.1:8787` points a build
    /// at a mock server.
    var baseURL: URL {
        if let baseURLOverride { return baseURLOverride }
        if let s = UserDefaults.standard.string(forKey: Self.baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, let u = URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s) {
            return u
        }
        return URL(string: Self.defaultBaseURL)!
    }

    /// `NaviSettings.useCloud` (default true), read off the main actor.
    var useCloud: Bool {
        UserDefaults.standard.object(forKey: Self.useCloudKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.useCloudKey)
    }

    /// A session exists (tokens in the store).
    var isSignedIn: Bool { tokens.accessToken != nil || tokens.refreshToken != nil }

    /// The rule every client follows: cloud when enabled and signed in, else BYOK.
    var isActive: Bool { useCloud && isSignedIn }

    // MARK: Requests

    func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    /// A JSON POST to the proxy carrying the feature/run headers. The bearer is
    /// attached by `send`/`bytes` so a refreshed token is used on retry.
    func request(path: String, body: Data, run: CloudRun, extraHeaders: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(run.feature.rawValue, forHTTPHeaderField: "X-Navi-Feature")
        req.setValue(run.runID.uuidString.lowercased(), forHTTPHeaderField: "X-Navi-Run")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    func request(path: String, json: [String: Any], run: CloudRun, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        request(path: path, body: try JSONSerialization.data(withJSONObject: json), run: run, extraHeaders: extraHeaders)
    }

    func get(path: String) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = "GET"
        return req
    }

    /// Sends an authenticated request. Refreshes the session once on 401.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        try await attachBearer(&req)
        var (data, http) = try await perform(req)
        if http.statusCode == 401 {
            Log.app.info("cloud: 401 on \(req.url?.path ?? "?", privacy: .public); refreshing session")
            guard await refresher.refresh(using: self) else { throw NaviError.signedOut }
            try await attachBearer(&req)
            (data, http) = try await perform(req)
            if http.statusCode == 401 { await signOutLocally(); throw NaviError.signedOut }
        }
        try Self.check(http, body: data, path: req.url?.path ?? "")
        return (data, http)
    }

    /// Sends an authenticated request and returns the response body as a byte
    /// stream (SSE). Same 401/402/403 handling as `send` — errors are always
    /// decided before the first byte of a successful stream.
    func bytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var req = request
        try await attachBearer(&req)
        var (bytes, http) = try await performStream(req)
        if http.statusCode == 401 {
            Log.app.info("cloud: 401 on \(req.url?.path ?? "?", privacy: .public) (stream); refreshing session")
            guard await refresher.refresh(using: self) else { throw NaviError.signedOut }
            try await attachBearer(&req)
            (bytes, http) = try await performStream(req)
            if http.statusCode == 401 { await signOutLocally(); throw NaviError.signedOut }
        }
        if !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line }
            try Self.check(http, body: Data(text.utf8), path: req.url?.path ?? "")
        }
        return (bytes, http)
    }

    /// Unauthenticated JSON POST (auth exchange/refresh).
    func post(path: String, json: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, http) = try await perform(req)
        try Self.check(http, body: data, path: path)
        return (data, http)
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        await lastUse.touch()
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Navi Cloud") }
        return (data, http)
    }

    private func performStream(_ req: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, resp) = try await session.bytes(for: req)
        await lastUse.touch()
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Navi Cloud") }
        return (bytes, http)
    }

    private func attachBearer(_ req: inout URLRequest) async throws {
        // Proactive refresh when the access token is about to lapse, so a
        // streaming answer never starts on a token that dies mid-flight.
        if let exp = tokens.accessExpiresAt, exp.timeIntervalSinceNow < 30, tokens.refreshToken != nil {
            _ = await refresher.refresh(using: self)
        }
        guard let token = tokens.accessToken, !token.isEmpty else {
            if tokens.refreshToken != nil, await refresher.refresh(using: self), let t = tokens.accessToken {
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                return
            }
            throw NaviError.signedOut
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: Errors

    /// `{error, feature, tier, resetsAt}` from a 402/403.
    struct ErrorBody: Decodable {
        var error: String?
        var message: String?
        var feature: String?
        var tier: String?
        var resetsAt: Date?

        private enum CodingKeys: String, CodingKey { case error, message, feature, tier, resetsAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            feature = try? c.decodeIfPresent(String.self, forKey: .feature)
            tier = try? c.decodeIfPresent(String.self, forKey: .tier)
            resetsAt = try c.decodeLenientDateIfPresent(forKey: .resetsAt)
        }
    }

    /// Maps a non-2xx proxy response to a typed `NaviError`.
    static func check(_ http: HTTPURLResponse, body: Data, path: String) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let text = String(data: body, encoding: .utf8) ?? ""
        let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body)
        switch http.statusCode {
        case 401:
            throw NaviError.signedOut
        case 402:
            Log.app.info("cloud: quota exceeded (\(parsed?.feature ?? "?", privacy: .public), \(parsed?.tier ?? "?", privacy: .public))")
            throw NaviError.quotaExceeded(feature: parsed?.feature ?? "", tier: parsed?.tier ?? "", resetsAt: parsed?.resetsAt)
        case 403:
            Log.app.info("cloud: not entitled (\(parsed?.feature ?? "?", privacy: .public), \(parsed?.tier ?? "?", privacy: .public))")
            throw NaviError.notEntitled(feature: parsed?.feature ?? "", tier: parsed?.tier ?? "")
        case 429:
            throw NaviError.other("Navi is busy right now — try again in a moment.")
        default:
            Log.app.error("cloud: HTTP \(http.statusCode) on \(path, privacy: .public): \(text.prefix(300))")
            throw NaviError.http(status: http.statusCode, body: parsed?.message ?? parsed?.error ?? text)
        }
    }

    // MARK: Session lifecycle

    struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresAt = try c.decodeLenientDateIfPresent(forKey: .expiresAt)
        }
    }

    /// `POST /auth/exchange { code }` → tokens into the store.
    func exchange(code: String) async throws {
        let (data, _) = try await post(path: "/auth/exchange", json: ["code": code])
        let t = try Self.decodeTokens(data)
        tokens.store(access: t.accessToken, refresh: t.refreshToken, expiresAt: t.expiresAt)
        Log.app.info("cloud: session established")
    }

    /// `POST /auth/refresh { refreshToken }`. Returns false (and signs out) when the session is gone.
    fileprivate func performRefresh() async -> Bool {
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
            await signOutLocally(); return false
        }
        do {
            let (data, _) = try await post(path: "/auth/refresh", json: ["refreshToken": refresh])
            let t = try Self.decodeTokens(data)
            tokens.store(access: t.accessToken, refresh: t.refreshToken ?? refresh, expiresAt: t.expiresAt)
            Log.app.info("cloud: session refreshed")
            return true
        } catch {
            // Only an auth failure ends the session; a network blip keeps the tokens.
            if case NaviError.signedOut = error { await signOutLocally() }
            else if case NaviError.http(let s, _) = error, (400..<500).contains(s) { await signOutLocally() }
            Log.app.error("cloud: refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func decodeTokens(_ data: Data) throws -> TokenResponse {
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw NaviError.decoding("Auth response: \(error.localizedDescription)") }
    }

    /// Clears the session and tells `NaviAccount` (on the main actor).
    func signOutLocally() async {
        guard isSignedIn else { return }
        tokens.clear()
        Log.app.info("cloud: signed out")
        await MainActor.run {
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil, userInfo: ["signedOut": true])
        }
    }

    /// `GET /v1/me`.
    func me() async throws -> AccountInfo {
        let (data, _) = try await send(get(path: "/v1/me"))
        return try AccountInfo.decode(data)
    }

    /// `POST /billing/checkout` / `/billing/portal` → the URL to open.
    func billingURL(path: String, json: [String: Any]) async throws -> URL {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, _) = try await send(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["url"] as? String, let u = URL(string: s) else {
            throw NaviError.decoding("Billing response has no url")
        }
        return u
    }

    // MARK: Warm-up

    static let warmAfterIdleSeconds: TimeInterval = 20

    /// Opens the TLS connection to the proxy ahead of the first call (`HEAD /`).
    /// Fire-and-forget; one warm covers Jev and Claude since they share the host.
    func warm() {
        guard isActive else { return }
        Task.detached(priority: .userInitiated) { [self] in
            guard await lastUse.isColder(than: Self.warmAfterIdleSeconds) else { return }
            var req = URLRequest(url: baseURL)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 5
            let start = Date()
            _ = try? await session.data(for: req)
            await lastUse.touch()
            Log.app.debug("cloud: connection warmed in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    // MARK: Internals

    /// Single-flight refresh: concurrent 401s share one `/auth/refresh`.
    private actor Refresher {
        private var inflight: Task<Bool, Never>?
        func refresh(using transport: CloudTransport) async -> Bool {
            if let inflight { return await inflight.value }
            let t = Task { await transport.performRefresh() }
            inflight = t
            let ok = await t.value
            inflight = nil
            return ok
        }
    }

    private actor LastUse {
        private var at: Date?
        func touch() { at = Date() }
        func isColder(than seconds: TimeInterval) -> Bool {
            guard let at else { return true }
            return Date().timeIntervalSince(at) > seconds
        }
    }
}

extension Notification.Name {
    /// Sign-in, sign-out, or a fresh `/v1/me` snapshot. userInfo `signedOut: true` on forced sign-out.
    static let naviAccountChanged = Notification.Name("navi.accountChanged")
}
