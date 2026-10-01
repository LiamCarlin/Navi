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
        let t = UserDefaults.navi.double(forKey: Self.expiresKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func store(access: String, refresh: String?, expiresAt: Date?) {
        Keychain.set(.naviAccess, value: access)
        if let refresh { Keychain.set(.naviRefresh, value: refresh) }
        UserDefaults.navi.set(expiresAt?.timeIntervalSince1970 ?? 0, forKey: Self.expiresKey)
    }
    func clear() {
        Keychain.set(.naviAccess, value: nil)
        Keychain.set(.naviRefresh, value: nil)
        UserDefaults.navi.removeObject(forKey: Self.expiresKey)
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
/// decode `{error, feature, tier, resetsAt}` into `.quotaExceeded` / `.notEntitled`;
/// 403 `account_disabled`, 426 `upgrade_required` and 503 `feature_disabled` map to
/// `.accountDisabled` / `.upgradeRequired` / `.featureDisabled` and are remembered
/// (`block`, `disabledFeatures`) so later calls fail fast until `/v1/me` says otherwise.
/// Every request carries `X-Navi-Version`.
final class CloudTransport: @unchecked Sendable {
    static let shared: CloudTransport = {
        #if DEBUG
        if let dev = DevCloud.current {
            // A Debug run pointed at a local cloud keeps its session in memory, so it
            // never writes the installed app's Keychain item (see `DevCloud`).
            return CloudTransport(baseURL: dev.baseURL,
                                  tokens: MemoryTokenStore(access: dev.accessToken, refresh: dev.refreshToken))
        }
        #endif
        return CloudTransport()
    }()

    /// The production API when the build names none (project.yml `NaviCloudBaseURL`).
    static let fallbackBaseURL = "https://api.navi.app"
    /// The build's `NaviCloudBaseURL` Info.plist key (set in project.yml, like the update
    /// feed), else `fallbackBaseURL`. The `cloudBaseURL` default still overrides it.
    static let defaultBaseURL: String = resolveDefaultBaseURL(
        infoPlist: Bundle.main.object(forInfoDictionaryKey: "NaviCloudBaseURL") as? String)

    static func resolveDefaultBaseURL(infoPlist: String?) -> String {
        guard var s = infoPlist?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["https", "http"].contains(scheme), u.host != nil
        else { return fallbackBaseURL }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    static let baseURLKey = "cloudBaseURL"
    static let useCloudKey = "useCloud"
    /// Sent on every cloud request so the server can refuse builds it no longer serves (426).
    static let versionHeader = "X-Navi-Version"

    let session: URLSession
    let tokens: CloudTokenStore
    private let baseURLOverride: URL?
    private let refresher = Refresher()
    private let lastUse = LastUse()
    private let gate = Gate()

    init(session: URLSession? = nil, baseURL: URL? = nil, tokens: CloudTokenStore = KeychainTokenStore()) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600     // streaming answers and agent turns
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = ["User-Agent": "Navi/\(Self.appVersion) (macOS)"]
            self.session = URLSession(configuration: TestHost.guarded(cfg))
        }
        self.baseURLOverride = baseURL
        self.tokens = tokens
    }

    /// `CFBundleShortVersionString`, the value of `X-Navi-Version`.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    /// Every request — proxy, auth, billing, account, warm-up — says which build sent it.
    static func stamp(_ req: inout URLRequest) {
        req.setValue(appVersion, forHTTPHeaderField: versionHeader)
    }

    // MARK: Selection

    /// `NaviSettings.cloudBaseURL`, read off the main actor. `defaults write
    /// com.liamcarlin.navi cloudBaseURL http://127.0.0.1:8787` points a build
    /// at a mock server.
    var baseURL: URL {
        if let baseURLOverride { return baseURLOverride }
        if let s = UserDefaults.navi.string(forKey: Self.baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, let u = URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s) {
            return u
        }
        return URL(string: Self.defaultBaseURL)!
    }

    /// `NaviSettings.useCloud` (default true), read off the main actor.
    var useCloud: Bool {
        UserDefaults.navi.object(forKey: Self.useCloudKey) == nil ? true : UserDefaults.navi.bool(forKey: Self.useCloudKey)
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
        try preflight(req)
        let used = try await attachBearer(&req)
        var (data, http) = try await perform(req)
        if http.statusCode == 401 {
            Log.app.info("cloud: 401 on \(req.url?.path ?? "?", privacy: .public); refreshing session")
            guard await refresher.refresh(using: self, replacing: used) else { throw NaviError.signedOut }
            try attachFreshBearer(&req)
            (data, http) = try await perform(req)
            if http.statusCode == 401 { await signOutLocally(); throw NaviError.signedOut }
        }
        try checkNoting(http, body: data, path: req.url?.path ?? "")
        noteTier(in: http)
        return (data, http)
    }

    /// Sends an authenticated request and returns the response body as a byte
    /// stream (SSE). Same 401/402/403 handling as `send` — errors are always
    /// decided before the first byte of a successful stream.
    func bytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var req = request
        try preflight(req)
        let used = try await attachBearer(&req)
        var (bytes, http) = try await performStream(req)
        if http.statusCode == 401 {
            Log.app.info("cloud: 401 on \(req.url?.path ?? "?", privacy: .public) (stream); refreshing session")
            guard await refresher.refresh(using: self, replacing: used) else { throw NaviError.signedOut }
            try attachFreshBearer(&req)
            (bytes, http) = try await performStream(req)
            if http.statusCode == 401 { await signOutLocally(); throw NaviError.signedOut }
        }
        if !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line }
            try checkNoting(http, body: Data(text.utf8), path: req.url?.path ?? "")
        }
        noteTier(in: http)
        return (bytes, http)
    }

    /// Unauthenticated JSON POST (auth exchange/refresh).
    func post(path: String, json: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, http) = try await perform(req)
        try checkNoting(http, body: data, path: path)
        return (data, http)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        Self.stamp(&req)
        let (data, resp) = try await session.data(for: req)
        await lastUse.touch()
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Navi Cloud") }
        return (data, http)
    }

    private func performStream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var req = request
        Self.stamp(&req)
        let (bytes, resp) = try await session.bytes(for: req)
        await lastUse.touch()
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response from Navi Cloud") }
        return (bytes, http)
    }

    /// Attaches the bearer for a first attempt and returns the token used, so a
    /// 401 can tell the refresher which token it saw fail.
    @discardableResult
    private func attachBearer(_ req: inout URLRequest) async throws -> String? {
        // Proactive refresh when the access token is about to lapse, so a
        // streaming answer never starts on a token that dies mid-flight.
        if let exp = tokens.accessExpiresAt, exp.timeIntervalSinceNow < 30, tokens.refreshToken != nil {
            _ = await refresher.refresh(using: self, replacing: tokens.accessToken)
        }
        if tokens.accessToken?.isEmpty ?? true, tokens.refreshToken != nil {
            _ = await refresher.refresh(using: self, replacing: tokens.accessToken)
        }
        guard let token = tokens.accessToken, !token.isEmpty else { throw NaviError.signedOut }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return token
    }

    /// Attaches the token a refresh just produced, for the single retry after a
    /// 401. No proactive refresh here: a new token whose `expiresAt` already
    /// reads as lapsed (clock skew, a short-lived token) must not be refreshed
    /// a second time — each 401 retries once, on one refresh.
    private func attachFreshBearer(_ req: inout URLRequest) throws {
        guard let token = tokens.accessToken, !token.isEmpty else { throw NaviError.signedOut }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: Errors

    /// The proxy's error body: `{error, feature, tier, resetsAt}` on 402/403,
    /// `{error:"account_disabled", message}` on 403,
    /// `{error:"upgrade_required", minAppVersion, downloadURL}` on 426,
    /// `{error:"rate_limited", retryAfterSeconds}` on 429,
    /// `{error:"upstream_unconfigured"|"billing_unconfigured"}` or
    /// `{error:"feature_disabled", feature, message}` on 503.
    struct ErrorBody: Decodable {
        var error: String?
        var message: String?
        var feature: String?
        var tier: String?
        var resetsAt: Date?
        var retryAfterSeconds: Double?
        var minAppVersion: String?
        var downloadURL: URL?

        private enum CodingKeys: String, CodingKey {
            case error, message, feature, tier, resetsAt, retryAfterSeconds, minAppVersion, downloadURL
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            feature = try? c.decodeIfPresent(String.self, forKey: .feature)
            tier = try? c.decodeIfPresent(String.self, forKey: .tier)
            resetsAt = try c.decodeLenientDateIfPresent(forKey: .resetsAt)
            retryAfterSeconds = try? c.decodeIfPresent(Double.self, forKey: .retryAfterSeconds)
            minAppVersion = try? c.decodeIfPresent(String.self, forKey: .minAppVersion)
            let rawURL: String? = (try? c.decodeIfPresent(String.self, forKey: .downloadURL)) ?? nil
            downloadURL = rawURL.flatMap(URL.init(string:))
        }
    }

    /// Maps a non-2xx proxy response to a typed `NaviError`. Vendor errors the
    /// proxy passes through keep their status and body (`.http`).
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
        case 403 where parsed?.error == "account_disabled":
            Log.app.error("cloud: account disabled")
            throw NaviError.accountDisabled(message: parsed?.message)
        case 403:
            Log.app.info("cloud: not entitled (\(parsed?.feature ?? "?", privacy: .public), \(parsed?.tier ?? "?", privacy: .public))")
            throw NaviError.notEntitled(feature: parsed?.feature ?? "", tier: parsed?.tier ?? "")
        case 426:
            Log.app.error("cloud: upgrade required (this build \(appVersion, privacy: .public), min \(parsed?.minAppVersion ?? "?", privacy: .public))")
            throw NaviError.upgradeRequired(minAppVersion: parsed?.minAppVersion, downloadURL: parsed?.downloadURL)
        case 503 where parsed?.error == "feature_disabled":
            Log.app.info("cloud: feature disabled (\(parsed?.feature ?? "?", privacy: .public))")
            throw NaviError.featureDisabled(feature: parsed?.feature ?? "", message: parsed?.message)
        case 429:
            let wait = parsed?.retryAfterSeconds.map { max(1, Int($0.rounded(.up))) }
            Log.app.info("cloud: rate limited (retry after \(wait ?? 0)s)")
            throw NaviError.other(wait.map { "Navi is busy, try again in \($0) second\($0 == 1 ? "" : "s")." }
                                  ?? "Navi is busy, try again in a moment.")
        case 503 where parsed?.error == "upstream_unconfigured" || parsed?.error == "billing_unconfigured":
            Log.app.error("cloud: \(parsed?.error ?? "unconfigured", privacy: .public)")
            throw NaviError.other("Navi isn't set up yet.")
        default:
            Log.app.error("cloud: HTTP \(http.statusCode) on \(path, privacy: .public): \(text.prefix(300))")
            throw NaviError.http(status: http.statusCode, body: parsed?.message ?? parsed?.error ?? text)
        }
    }

    /// `check`, plus remembering the errors that change what later calls may do:
    /// a disabled account or a too-old build stops proxy calls; a feature the
    /// operator switched off stops that feature until the next `/v1/me`.
    private func checkNoting(_ http: HTTPURLResponse, body: Data, path: String) throws {
        do { try Self.check(http, body: body, path: path) }
        catch let e as NaviError { note(e); throw e }
    }

    // MARK: Blocks and kill switches

    /// A reason the cloud won't serve this app at all right now.
    enum Block: Equatable, Sendable {
        case accountDisabled(message: String?)
        case upgradeRequired(minAppVersion: String?, downloadURL: URL?)

        var error: NaviError {
            switch self {
            case .accountDisabled(let m): return .accountDisabled(message: m)
            case .upgradeRequired(let v, let u): return .upgradeRequired(minAppVersion: v, downloadURL: u)
            }
        }
    }

    /// The current block, if any (set by a 403 `account_disabled` / 426, or by `/v1/me.config`).
    var block: Block? { gate.read { $0.block } }

    /// `config.features` keys that are switched off ("answers", "tasks", …).
    var disabledFeatures: Set<String> { gate.read { $0.disabled } }

    /// Proxy calls stop while blocked; `/v1/me` (to notice the block lifting),
    /// `/v1/account*` (export, delete) and auth/billing always go through.
    static func isBlockable(path: String) -> Bool {
        guard let r = path.range(of: "/v1/") else { return false }
        let rest = path[r.upperBound...]
        return rest != "me" && !rest.hasPrefix("account")
    }

    /// Refuses, without a network round trip, what the cloud would refuse anyway.
    func preflight(_ req: URLRequest) throws {
        if let block, Self.isBlockable(path: req.url?.path ?? "") { throw block.error }
        if let raw = req.value(forHTTPHeaderField: "X-Navi-Feature"), let f = CloudFeature(rawValue: raw),
           let key = CloudConfig.Features.key(for: f), disabledFeatures.contains(key) {
            throw NaviError.featureDisabled(feature: key, message: nil)
        }
    }

    /// A successful `/v1/me` is the server's word: the account is enabled, the
    /// kill switches are what `config` says, and the build is too old only if
    /// `config.minAppVersion` says so.
    func apply(_ info: AccountInfo) {
        let config = info.config ?? CloudConfig()
        let block: Block? = config.requiresUpdate(currentVersion: Self.appVersion)
            ? .upgradeRequired(minAppVersion: config.minAppVersion, downloadURL: config.downloadURL) : nil
        gate.write { $0.block = block; $0.disabled = config.features.disabled }
    }

    /// Sign-in / sign-out start from a clean slate.
    func clearBlocks() { gate.write { $0.block = nil; $0.disabled = [] } }

    private func note(_ error: NaviError) {
        switch error {
        case .accountDisabled(let m):
            gate.write { $0.block = .accountDisabled(message: m) }
        case .upgradeRequired(let v, let u):
            gate.write { $0.block = .upgradeRequired(minAppVersion: v, downloadURL: u) }
        case .featureDisabled(let f, _):
            let key = CloudFeature(rawValue: f).flatMap(CloudConfig.Features.key(for:)) ?? f
            guard !key.isEmpty else { return }
            gate.write { $0.disabled.insert(key) }
        default:
            return
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .naviCloudBlocked, object: nil, userInfo: ["error": error])
        }
    }

    /// The proxy echoes `X-Navi-Tier` on every response: a change (upgrade,
    /// trial end) refreshes the cached account without waiting for the timer.
    static let tierHeader = "X-Navi-Tier"

    private func noteTier(in http: HTTPURLResponse) {
        guard let tier = http.value(forHTTPHeaderField: Self.tierHeader), !tier.isEmpty else { return }
        NotificationCenter.default.post(name: .naviCloudTierSeen, object: nil, userInfo: ["tier": tier])
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

    /// True when a token expiring at `expiresAt` would lapse within `lifetime`. An unknown
    /// expiry is trusted (a 401 is the backstop).
    static func needsRefresh(expiresAt: Date?, validFor lifetime: TimeInterval, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < lifetime
    }

    /// An access token that stays valid for at least `lifetime`, for a process that cannot
    /// refresh one itself (the bundled browser runner never sees the refresh token). When the
    /// current token would lapse sooner it is refreshed first, through the same single-flight
    /// refresher every request uses. A refresh that fails on the network still yields a token
    /// that has not expired; nil when signed out (an auth failure on refresh signs out).
    func accessToken(validFor lifetime: TimeInterval, now: Date = Date()) async -> String? {
        let current = tokens.accessToken.flatMap { $0.isEmpty ? nil : $0 }
        if let current, !Self.needsRefresh(expiresAt: tokens.accessExpiresAt, validFor: lifetime, now: now) { return current }
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            _ = await refresher.refresh(using: self, replacing: current)
        }
        guard let token = tokens.accessToken, !token.isEmpty else { return nil }
        if let exp = tokens.accessExpiresAt, exp <= now { return nil }
        return token
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
        clearBlocks()
        Log.app.info("cloud: signed out")
        await MainActor.run {
            NotificationCenter.default.post(name: .naviAccountChanged, object: nil, userInfo: ["signedOut": true])
        }
    }

    /// `GET /v1/me`.
    func me() async throws -> AccountInfo {
        let (data, _) = try await send(get(path: "/v1/me"))
        let info = try AccountInfo.decode(data)
        apply(info)
        return info
    }

    /// `GET /v1/account/export` → everything the cloud holds about the account, as JSON.
    func exportAccount() async throws -> Data {
        let (data, _) = try await send(get(path: "/v1/account/export"))
        return data
    }

    /// `DELETE /v1/account` → 204. The caller signs out locally afterwards.
    func deleteAccount() async throws {
        var req = URLRequest(url: url("/v1/account"))
        req.httpMethod = "DELETE"
        _ = try await send(req)
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
            Self.stamp(&req)
            let start = Date()
            _ = try? await session.data(for: req)
            await lastUse.touch()
            Log.app.debug("cloud: connection warmed in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    // MARK: Internals

    /// Single-flight refresh: concurrent 401s share one `/auth/refresh`.
    /// `replacing` is the access token the caller saw fail (or lapse). When the
    /// store already holds a different one, another request refreshed after
    /// this one was sent — a 401 that lands just after a refresh finished must
    /// reuse it, not rotate the session again.
    private actor Refresher {
        private var inflight: Task<Bool, Never>?
        func refresh(using transport: CloudTransport, replacing stale: String?) async -> Bool {
            if let inflight { return await inflight.value }
            if let current = transport.tokens.accessToken, !current.isEmpty, current != stale { return true }
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

    /// Block + kill switches, read on whatever thread a request is built on.
    private final class Gate: @unchecked Sendable {
        struct State { var block: Block?; var disabled: Set<String> = [] }
        private let lock = NSLock()
        private var state = State()
        func read<T>(_ f: (State) -> T) -> T { lock.withLock { f(state) } }
        func write(_ f: (inout State) -> Void) { lock.withLock { f(&state) } }
    }
}

#if DEBUG
/// Debug-only: run a build against a local Navi Cloud without touching the
/// installed app's account. Launch the Debug binary with
/// `NAVI_DEV_CLOUD=http://localhost:3100` (optionally `NAVI_DEV_ACCESS_TOKEN` /
/// `NAVI_DEV_REFRESH_TOKEN` from `POST /auth/dev-login`): the session lives in
/// memory, the Keychain is neither read nor written, and the account snapshot
/// and dismissed notices go to a separate defaults suite. Release builds ignore it.
struct DevCloud {
    let baseURL: URL
    let accessToken: String?
    let refreshToken: String?

    static let defaultsSuite = "com.liamcarlin.navi.devcloud"

    static let current: DevCloud? = {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["NAVI_DEV_CLOUD"], let url = URL(string: s), url.scheme != nil else { return nil }
        func nonEmpty(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
        return DevCloud(baseURL: url, accessToken: nonEmpty("NAVI_DEV_ACCESS_TOKEN"), refreshToken: nonEmpty("NAVI_DEV_REFRESH_TOKEN"))
    }()

    static var defaults: UserDefaults? { current == nil ? nil : UserDefaults(suiteName: defaultsSuite) }
}
#endif

extension Notification.Name {
    /// The cloud refused this app for a reason that outlives the call: account
    /// disabled, build too old, or a feature switched off. userInfo `error: NaviError`.
    static let naviCloudBlocked = Notification.Name("navi.cloudBlocked")
    /// Sign-in, sign-out, or a fresh `/v1/me` snapshot. userInfo `signedOut: true` on forced sign-out.
    static let naviAccountChanged = Notification.Name("navi.accountChanged")
    /// A proxy response carried `X-Navi-Tier` (userInfo `tier`). `NaviAccount` refreshes when it differs.
    static let naviCloudTierSeen = Notification.Name("navi.cloudTierSeen")
}
