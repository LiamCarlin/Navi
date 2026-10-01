import Testing
import Foundation
@testable import Navi

// The launch contract on top of §3.1: `/v1/me.config`, `X-Navi-Version`,
// 426 / 503 feature_disabled / 403 account_disabled, export + delete, notices.
// Network goes through `StubProtocol` (CloudTransportTests.swift), one host per test.

private func stubTransport(_ host: String, tokens: MemoryTokenStore = MemoryTokenStore(access: "acc-1", refresh: "ref-1")) -> CloudTransport {
    CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
}

/// A throwaway defaults suite so account snapshots and dismissed notices never touch the app's own.
private func scratchDefaults(_ name: String) -> UserDefaults {
    let suite = "navi.tests.\(name).\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

private func meJSON(config: String? = nil, tier: String = "pro") -> String {
    """
    {"user":{"id":"u_1","email":"liam@example.com"},"tier":"\(tier)",
     "entitlements":{"answers":true,"tasks":true,"voice":true,"recall":false},
     "quotas":{"answersPerDay":500,"tasksPerMonth":300},
     "usage":{"answersToday":3,"tasksThisMonth":7}\(config.map { ",\"config\":\($0)" } ?? "")}
    """
}

private func reply(_ status: Int, _ json: String) -> StubProtocol.Reply {
    StubProtocol.Reply(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
}

// MARK: - /v1/me with and without config

struct MeConfigDecodingTests {
    @Test func withoutConfigEverythingIsOn() throws {
        let me = try AccountInfo.decode(Data(meJSON().utf8))
        #expect(me.config == nil)
        let config = me.config ?? CloudConfig()
        #expect(config.features == CloudConfig.Features())
        #expect(config.features.disabled.isEmpty)
        #expect(config.notice == nil && config.minAppVersion == nil && config.downloadURL == nil)
        #expect(!config.requiresUpdate(currentVersion: "0.1.0"))
    }

    @Test func fullConfig() throws {
        let me = try AccountInfo.decode(Data(meJSON(config: """
        {"features":{"answers":true,"tasks":false,"voice":true,"recall":false},
         "notice":{"id":"n-42","message":"Tasks are paused while we fix a bug.","level":"critical","url":"https://navi.app/status"},
         "minAppVersion":"0.4.0","latestVersion":"0.5.1","downloadURL":"https://navi.app/download"}
        """).utf8))
        let c = try #require(me.config)
        #expect(c.features.answers && !c.features.tasks && c.features.voice && !c.features.recall)
        #expect(c.features.disabled == ["tasks", "recall"])
        #expect(!c.features.allows(.task) && !c.features.allows(.recallDigest) && c.features.allows(.answer) && c.features.allows(.route))
        #expect(c.notice == CloudConfig.Notice(id: "n-42", message: "Tasks are paused while we fix a bug.", level: .critical,
                                               url: URL(string: "https://navi.app/status")))
        #expect(c.minAppVersion == "0.4.0" && c.latestVersion == "0.5.1")
        #expect(c.downloadURL == URL(string: "https://navi.app/download"))
        #expect(c.requiresUpdate(currentVersion: "0.3.9") && !c.requiresUpdate(currentVersion: "0.4.0"))
        #expect(c.updateAvailable(currentVersion: "0.5.0") && !c.updateAvailable(currentVersion: "0.5.1"))
        // The cached snapshot keeps the config.
        #expect(try AccountInfo.decode(JSONEncoder().encode(me)) == me)
    }

    @Test func partialAndMalformedConfigNeverFailsTheAccount() throws {
        // Missing feature flags read as on; an unknown level as info; junk fields are dropped.
        let me = try AccountInfo.decode(Data(meJSON(config: """
        {"features":{"tasks":false},"notice":{"id":"n1","message":"Heads up","level":"maintenance"},
         "minAppVersion":42,"latestVersion":"","downloadURL":7}
        """).utf8))
        let c = try #require(me.config)
        #expect(c.features == CloudConfig.Features(answers: true, tasks: false, voice: true, recall: true))
        #expect(c.notice?.level == .info && c.notice?.url == nil)
        #expect(c.minAppVersion == nil && c.latestVersion == nil && c.downloadURL == nil)

        // A notice without a message, a features object of the wrong type: still an account.
        let worse = try AccountInfo.decode(Data(meJSON(config: #"{"features":"off","notice":{"id":"x"}}"#).utf8))
        #expect(worse.config?.features == CloudConfig.Features())
        #expect(worse.config?.notice == nil)
        #expect(worse.user.email == "liam@example.com")

        // `config` itself of the wrong type.
        let odd = try AccountInfo.decode(Data(meJSON(config: "\"nope\"").utf8))
        #expect(odd.config == nil && odd.tier == .pro)
    }
}

// MARK: - X-Navi-Version

struct VersionHeaderTests {
    @Test func everyRequestSaysWhichBuildSentIt() async throws {
        let host = "version.test"
        StubProtocol.install(host: host) { req in
            switch req.url!.path {
            case "/auth/exchange": return StubProtocol.json(200, ["accessToken": "acc-x", "refreshToken": "ref-x"])
            case "/v1/me": return reply(200, meJSON())
            default: return reply(200, #"{"ok":true}"#)
            }
        }
        let cloud = stubTransport(host, tokens: MemoryTokenStore())
        try await cloud.exchange(code: "abc")                                   // unauthenticated POST
        _ = try await cloud.me()                                                 // authenticated GET
        _ = try await cloud.send(cloud.request(path: "/v1/jev", json: [:], run: CloudRun(feature: .route)))
        let (_, http) = try await cloud.bytes(cloud.request(path: "/v1/claude", json: [:], run: CloudRun(feature: .answer)))
        #expect(http.statusCode == 200)
        let sent = StubProtocol.requests(host: host)
        #expect(sent.count == 4)
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(CloudTransport.appVersion == version)
        for req in sent {
            #expect(req.value(forHTTPHeaderField: "X-Navi-Version") == version, "missing on \(req.url!.path)")
        }
    }
}

// MARK: - New error mappings

struct NewCloudErrorTests {
    @Test func upgradeRequiredStopsProxyCallsUntilMeSaysOtherwise() async throws {
        let host = "upgrade.test"
        let meAllowed = Flag()
        StubProtocol.install(host: host) { req in
            if req.url!.path == "/v1/me", meAllowed.value { return reply(200, meJSON()) }
            return reply(426, #"{"error":"upgrade_required","minAppVersion":"9.0.0","downloadURL":"https://navi.app/download"}"#)
        }
        let cloud = stubTransport(host)
        let claude = try cloud.request(path: "/v1/claude", json: [:], run: CloudRun(feature: .answer))
        do { _ = try await cloud.send(claude); Issue.record("expected upgradeRequired") }
        catch NaviError.upgradeRequired(let min, let url) {
            #expect(min == "9.0.0" && url == URL(string: "https://navi.app/download"))
        }
        #expect(cloud.block == .upgradeRequired(minAppVersion: "9.0.0", downloadURL: URL(string: "https://navi.app/download")))

        // Next proxy call fails fast, no request.
        let before = StubProtocol.requests(host: host).count
        do { _ = try await cloud.send(claude); Issue.record("expected a local refusal") }
        catch NaviError.upgradeRequired {}
        #expect(StubProtocol.requests(host: host).count == before)

        // /v1/me still goes out; once it succeeds (no minAppVersion) the block lifts.
        meAllowed.set(true)
        _ = try await cloud.me()
        #expect(cloud.block == nil)
        #expect(StubProtocol.requests(host: host).last?.url?.path == "/v1/me")
    }

    @Test func configMinimumVersionBlocksWithoutA426() async throws {
        let host = "minversion.test"
        StubProtocol.install(host: host) { _ in reply(200, meJSON(config: #"{"minAppVersion":"999.0","downloadURL":"https://navi.app/dl"}"#)) }
        let cloud = stubTransport(host)
        _ = try await cloud.me()
        #expect(cloud.block == .upgradeRequired(minAppVersion: "999.0", downloadURL: URL(string: "https://navi.app/dl")))
        do { try cloud.preflight(cloud.request(path: "/v1/jev", json: [:], run: CloudRun(feature: .route))); Issue.record("expected a refusal") }
        catch NaviError.upgradeRequired {}
    }

    @Test func featureDisabledFromServerAndFromConfig() async throws {
        let host = "killswitch.test"
        StubProtocol.install(host: host) { req in
            switch req.url!.path {
            case "/v1/claude": return reply(503, #"{"error":"feature_disabled","feature":"answers","message":"Answers are paused for maintenance."}"#)
            case "/v1/me": return reply(200, meJSON(config: #"{"features":{"tasks":false}}"#))
            default: return reply(200, "{}")
            }
        }
        let cloud = stubTransport(host)
        let answer = try cloud.request(path: "/v1/claude", json: [:], run: CloudRun(feature: .answer))
        do { _ = try await cloud.send(answer); Issue.record("expected featureDisabled") }
        catch NaviError.featureDisabled(let feature, let message) {
            #expect(feature == "answers" && message == "Answers are paused for maintenance.")
            #expect(NaviError.featureDisabled(feature: feature, message: message).errorDescription == "Answers are paused for maintenance.")
        }
        #expect(cloud.disabledFeatures == ["answers"])
        // Answers now refused locally; routing (no switch) and tasks still go.
        let before = StubProtocol.requests(host: host).count
        do { try cloud.preflight(answer); Issue.record("expected a local refusal") }
        catch NaviError.featureDisabled(let f, _) { #expect(f == "answers") }
        _ = try await cloud.send(cloud.request(path: "/v1/jev", json: [:], run: CloudRun(feature: .route)))
        #expect(StubProtocol.requests(host: host).count == before + 1)

        // /v1/me replaces the switches with the server's: answers back on, tasks off.
        _ = try await cloud.me()
        #expect(cloud.disabledFeatures == ["tasks"])
        try cloud.preflight(answer)
        do { try cloud.preflight(cloud.request(path: "/v1/jev", json: [:], run: CloudRun(feature: .task))); Issue.record("tasks are off") }
        catch NaviError.featureDisabled(let f, nil) { #expect(f == "tasks") }
    }

    @Test func accountDisabledIsNotANotEntitled() async throws {
        let host = "disabled.test"
        StubProtocol.install(host: host) { req in
            switch req.url!.path {
            case "/v1/account/export": return reply(200, #"{"user":{"email":"liam@example.com"}}"#)
            default: return reply(403, #"{"error":"account_disabled","message":"This account is suspended."}"#)
            }
        }
        let cloud = stubTransport(host)
        do { _ = try await cloud.send(cloud.request(path: "/v1/jev", json: [:], run: CloudRun(feature: .route))); Issue.record("expected accountDisabled") }
        catch NaviError.accountDisabled(let m) { #expect(m == "This account is suspended.") }
        #expect(cloud.block == .accountDisabled(message: "This account is suspended."))
        // Proxy calls stop; export (and /v1/me) still go out.
        let before = StubProtocol.requests(host: host).count
        do { _ = try await cloud.send(cloud.request(path: "/v1/claude", json: [:], run: CloudRun(feature: .answer))); Issue.record("expected a refusal") }
        catch NaviError.accountDisabled {}
        #expect(StubProtocol.requests(host: host).count == before)
        let data = try await cloud.exportAccount()
        #expect(String(data: data, encoding: .utf8)?.contains("liam@example.com") == true)
        // A plain 403 is still an entitlement error.
        do {
            try CloudTransport.check(HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                                     body: Data(#"{"error":"not_entitled","feature":"voice","tier":"free"}"#.utf8), path: "/v1/jev")
            Issue.record("expected notEntitled")
        } catch NaviError.notEntitled(let f, let t) {
            #expect(f == "voice" && t == "free")
        }
        // Signing out starts clean.
        cloud.clearBlocks()
        #expect(cloud.block == nil)
    }

    @Test func blockablePaths() {
        #expect(CloudTransport.isBlockable(path: "/v1/jev"))
        #expect(CloudTransport.isBlockable(path: "/v1/claude"))
        #expect(CloudTransport.isBlockable(path: "/api/v1/digest"))
        #expect(!CloudTransport.isBlockable(path: "/v1/me"))
        #expect(!CloudTransport.isBlockable(path: "/v1/account"))
        #expect(!CloudTransport.isBlockable(path: "/v1/account/export"))
        #expect(!CloudTransport.isBlockable(path: "/auth/refresh"))
        #expect(!CloudTransport.isBlockable(path: "/billing/portal"))
    }

    @Test func everyNewErrorHasALineAndARecovery() {
        let update = NaviError.upgradeRequired(minAppVersion: "1.0", downloadURL: nil)
        #expect(update.errorDescription == "Update Navi to keep using it.")
        #expect(update.recovery == .updateApp && update.isAccountError)

        let off = NaviError.featureDisabled(feature: "task", message: nil)
        #expect(off.errorDescription == "Tasks are temporarily unavailable. Try again in a little while.")
        #expect(off.recovery == .tryLater)
        #expect(NaviError.featureDisabled(feature: "voice", message: "  ").errorDescription == "Voice control is temporarily unavailable. Try again in a little while.")
        #expect(NaviError.featureDisabled(feature: "recall_digest", message: nil).errorDescription == "Recall is temporarily unavailable. Try again in a little while.")

        let disabled = NaviError.accountDisabled(message: nil)
        #expect(disabled.errorDescription == "Your Navi account is disabled. Contact support to sort it out.")
        #expect(disabled.recovery == .contactSupport)
        #expect(NaviError.accountDisabled(message: "Suspended for chargeback.").errorDescription == "Suspended for chargeback.")

        // The panel shows them as one line plus their button (none for "try later").
        let u = PanelViewModel.accountPresentation(for: update, quotas: Quotas())
        #expect(u?.message == "Update Navi to keep using it." && u?.actionTitle == "Update")
        let d = PanelViewModel.accountPresentation(for: disabled, quotas: Quotas())
        #expect(d?.actionTitle == "Contact support")
        let f = PanelViewModel.accountPresentation(for: off, quotas: Quotas())
        #expect(f?.message.hasPrefix("Tasks are temporarily unavailable") == true && f?.actionTitle == "")
        // Signed out, worded for what was tried.
        #expect(PanelViewModel.accountPresentation(for: NaviError.signedOut, quotas: Quotas(), feature: .answer)?.message == "Sign in to use answers.")
        #expect(PanelViewModel.accountPresentation(for: NaviError.signedOut, quotas: Quotas(), feature: .task)?.message == "Sign in to use tasks.")
        #expect(NaviAccount.signInLine(for: .voice) == "Sign in to use voice control.")
        #expect(NaviAccount.signInLine(for: nil) == "Sign in to Navi to keep going.")
        // Older errors keep theirs.
        #expect(NaviError.quotaExceeded(feature: "answer", tier: "free", resetsAt: nil).recovery == .upgrade(recall: false))
        #expect(NaviError.notEntitled(feature: "recall_digest", tier: "pro").recovery == .upgrade(recall: true))
        #expect(NaviError.signedOut.recovery == .signIn)
    }

    @Test func blockerBeforeStartingCloudWork() {
        let off: Set<String> = ["tasks"]
        // Signed out without keys: sign in. With developer keys: go.
        #expect(NaviAccount.blocker(for: .answer, usesCloud: false, isSignedIn: false, hasDeveloperKeys: false, block: nil, disabled: []) .map { "\($0)" } == "\(NaviError.signedOut)")
        #expect(NaviAccount.blocker(for: .answer, usesCloud: false, isSignedIn: false, hasDeveloperKeys: true, block: nil, disabled: []) == nil)
        // On the cloud: a block wins, then the kill switch, else go.
        if case .upgradeRequired = NaviAccount.blocker(for: .answer, usesCloud: true, isSignedIn: true, hasDeveloperKeys: false,
                                                       block: .upgradeRequired(minAppVersion: nil, downloadURL: nil), disabled: off) {} else { Issue.record("expected upgradeRequired") }
        if case .featureDisabled(let f, _) = NaviAccount.blocker(for: .task, usesCloud: true, isSignedIn: true, hasDeveloperKeys: false, block: nil, disabled: off) {
            #expect(f == "tasks")
        } else { Issue.record("expected featureDisabled") }
        #expect(NaviAccount.blocker(for: .answer, usesCloud: true, isSignedIn: true, hasDeveloperKeys: false, block: nil, disabled: off) == nil)
        #expect(NaviAccount.blocker(for: .route, usesCloud: true, isSignedIn: true, hasDeveloperKeys: false, block: nil, disabled: ["answers", "tasks", "voice", "recall"]) == nil)
    }

    @Test func plainSentencesForAccountCalls() {
        #expect(NaviAccount.userMessage(for: NaviError.http(status: 400, body: "This sign-in link has expired or was already used. Sign in again."))
                == "This sign-in link has expired or was already used. Sign in again.")
        #expect(NaviAccount.userMessage(for: NaviError.http(status: 500, body: #"{"error":"internal"}"#)) == "Navi is having trouble right now. Try again in a moment.")
        #expect(NaviAccount.userMessage(for: NaviError.http(status: 404, body: "<html>nope</html>")) == "Something went wrong. Try again.")
        #expect(NaviAccount.userMessage(for: URLError(.notConnectedToInternet)) == "You're offline. Check your connection and try again.")
        #expect(NaviAccount.userMessage(for: URLError(.cannotConnectToHost)) == "Navi couldn't be reached. Try again in a moment.")
        #expect(NaviAccount.userMessage(for: NaviError.decoding("x")).contains("didn't understand"))
        #expect(NaviAccount.callbackErrorLine(error: "sign_in_failed", message: "Email link is invalid or has expired")
                == "Couldn't sign you in: email link is invalid or has expired. Try again.")
        #expect(NaviAccount.callbackErrorLine(error: "access_denied", message: nil) == "Sign-in was cancelled.")
        #expect(NaviAccount.callbackErrorLine(error: "sign_in_failed", message: "") == "Couldn't sign you in: sign in failed. Try again.")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set(_ b: Bool) { lock.withLock { v = b } }
    var value: Bool { lock.withLock { v } }
}

// MARK: - Notice dismissal memory

struct NoticeMemoryTests {
    @Test func dismissedIdsAreRememberedAndCapped() {
        let d = scratchDefaults("notices")
        let memory = NoticeMemory(defaults: d)
        let n = CloudConfig.Notice(id: "n-1", message: "Hello", level: .warning)
        #expect(memory.visible(n) == n)
        memory.dismiss("n-1")
        #expect(memory.visible(n) == nil)
        // Survives a new reader on the same defaults (a relaunch).
        #expect(NoticeMemory(defaults: d).isDismissed("n-1"))
        // A new notice id shows again.
        #expect(memory.visible(CloudConfig.Notice(id: "n-2", message: "Again")) != nil)
        memory.dismiss("n-1")
        #expect(memory.dismissed == ["n-1"])                       // no duplicates
        for i in 0..<(NoticeMemory.limit + 5) { memory.dismiss("bulk-\(i)") }
        #expect(memory.dismissed.count == NoticeMemory.limit)
        #expect(memory.dismissed.last == "bulk-\(NoticeMemory.limit + 4)")
        #expect(memory.visible(nil) == nil)
    }
}

// MARK: - The account object (main actor, stubbed network)

@MainActor
struct AccountLifecycleTests {
    private func signedInAccount(_ host: String, config: String?, defaults: UserDefaults, tokens: MemoryTokenStore = MemoryTokenStore(access: "acc-1", refresh: "ref-1")) throws -> NaviAccount {
        defaults.set(Data(meJSON(config: config).utf8), forKey: NaviAccount.snapshotKey)
        return NaviAccount(cloud: stubTransport(host, tokens: tokens), defaults: defaults)
    }

    @Test func noticesShowAndStayDismissed() throws {
        let d = scratchDefaults("acct-notice")
        let config = #"{"notice":{"id":"outage-7","message":"Answers are slow right now.","level":"critical"}}"#
        let account = try signedInAccount("acct-notice.test", config: config, defaults: d)
        #expect(account.isSignedIn)
        let n = try #require(account.homeNotice)
        #expect(n.id == "outage-7" && n.message == "Answers are slow right now." && n.kind == .config(url: nil))
        #expect(account.panelNotice == n)                          // critical ⇒ the panel shows it too
        account.dismiss(n)
        #expect(account.homeNotice == nil && account.panelNotice == nil)
        // A relaunch (new object, same defaults) keeps it dismissed.
        let again = try signedInAccount("acct-notice2.test", config: config, defaults: d)
        #expect(again.homeNotice == nil)
    }

    @Test func infoNoticesStayOutOfThePanel() throws {
        let d = scratchDefaults("acct-info")
        let account = try signedInAccount("acct-info.test", config: #"{"notice":{"id":"i1","message":"New: voice in any app.","url":"https://navi.app/changelog"}}"#, defaults: d)
        #expect(account.homeNotice?.kind == .config(url: URL(string: "https://navi.app/changelog")))
        #expect(account.homeNotice?.actionTitle == "Learn more")
        #expect(account.panelNotice == nil)
    }

    @Test func cachedConfigGatesBeforeTheNetworkAnswers() throws {
        let d = scratchDefaults("acct-gate")
        let account = try signedInAccount("acct-gate.test", config: #"{"features":{"answers":false},"minAppVersion":"0.0.1"}"#, defaults: d)
        #expect(!account.isAvailable(.answer) && account.isAvailable(.task))
        #expect(account.disabledFeatures == ["answers"])
        if case .featureDisabled(let f, _) = account.blocker(for: .answer) { #expect(f == "answers") } else { Issue.record("expected featureDisabled") }
        #expect(account.blocker(for: .task) == nil)
        #expect(!account.isUpdateRequired)
    }

    @Test func updateRequiredFromConfigShowsInPanelAndMenu() throws {
        let d = scratchDefaults("acct-update")
        let account = try signedInAccount("acct-update.test", config: #"{"minAppVersion":"999.0.0"}"#, defaults: d)
        #expect(account.isUpdateRequired)
        let n = try #require(account.panelNotice)
        #expect(n.kind == .updateRequired && n.actionTitle == "Update" && n.message == "Update Navi to keep using it.")
        account.dismiss(n)
        #expect(account.panelNotice == nil)                        // for this session
        #expect(account.isUpdateRequired)                          // the state itself stays
        #expect(account.menuTitle == "liam@example.com · Pro")
    }

    @Test func refreshAppliesConfigAndAccountDisabledFlows() async throws {
        let host = "acct-refresh.test"
        let disabled = Flag()
        StubProtocol.install(host: host) { req in
            if disabled.value { return reply(403, #"{"error":"account_disabled","message":"Suspended."}"#) }
            return reply(200, meJSON(config: #"{"features":{"voice":false}}"#))
        }
        let d = scratchDefaults("acct-refresh")
        let account = NaviAccount(cloud: stubTransport(host), defaults: d)
        await account.refreshMe(reason: "manual")
        #expect(account.info?.config?.features.voice == false)
        #expect(account.disabledFeatures == ["voice"])
        #expect(d.data(forKey: NaviAccount.snapshotKey) != nil)

        disabled.set(true)
        await account.refreshMe(reason: "manual")
        #expect(account.isAccountDisabled)
        #expect(account.lastError == nil)                          // explained by the Account page, not an error line
        #expect(account.isSignedIn)                                // still signed in: export/delete stay possible
        #expect(account.homeNotice?.kind == .accountDisabled)
        #expect(account.menuTitle == "liam@example.com · Disabled")
        if case .accountDisabled = account.blocker(for: .answer) {} else { Issue.record("expected accountDisabled") }
    }

    @Test func revokedRefreshTokenEndsInACleanSignedOutState() async throws {
        let host = "acct-revoked.test"
        StubProtocol.install(host: host) { req in
            req.url!.path == "/auth/refresh" ? reply(401, #"{"error":"invalid_grant"}"#) : reply(401, #"{"error":"unauthenticated"}"#)
        }
        let d = scratchDefaults("acct-revoked")
        let tokens = MemoryTokenStore(access: "acc-old", refresh: "ref-revoked")
        let account = try signedInAccount(host, config: nil, defaults: d, tokens: tokens)
        await account.refreshMe(reason: "manual")
        #expect(!account.isSignedIn && account.info == nil)
        #expect(tokens.accessToken == nil && tokens.refreshToken == nil)
        #expect(d.data(forKey: NaviAccount.snapshotKey) == nil)
        #expect(account.lastError == "You were signed out. Sign in again to keep using answers and tasks.")
        #expect(account.homeNotice == nil && account.menuTitle == nil)
    }

    @Test func callbackCodeIsExchangedThenMeIsFetched() async throws {
        let host = "acct-callback.test"
        StubProtocol.install(host: host) { req in
            switch req.url!.path {
            case "/auth/exchange": return StubProtocol.json(200, ["accessToken": "acc-new", "refreshToken": "ref-new", "expiresAt": "2030-01-01T00:00:00Z"])
            case "/v1/me":
                return req.value(forHTTPHeaderField: "Authorization") == "Bearer acc-new" ? reply(200, meJSON()) : reply(401, "{}")
            default: return reply(404, "{}")
            }
        }
        let d = scratchDefaults("acct-callback")
        let tokens = MemoryTokenStore()
        let account = NaviAccount(cloud: stubTransport(host, tokens: tokens), defaults: d)
        #expect(!account.isSignedIn)
        #expect(account.handle(url: URL(string: "navi://auth/callback?code=one-time")!))
        #expect(account.isSigningIn)
        for _ in 0..<100 where account.info == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(account.isSignedIn && !account.isSigningIn)
        #expect(account.email == "liam@example.com" && account.tier == .pro)
        #expect(tokens.accessToken == "acc-new" && tokens.refreshToken == "ref-new")
        #expect(StubProtocol.requests(host: host).map { $0.url!.path } == ["/auth/exchange", "/v1/me"])
        account.signOut()
        #expect(!account.isSignedIn && tokens.accessToken == nil && d.data(forKey: NaviAccount.snapshotKey) == nil)
    }

    @Test func expiredCodeSaysSoInPlainWords() async throws {
        let host = "acct-badcode.test"
        StubProtocol.install(host: host) { _ in
            reply(400, #"{"error":"invalid_code","message":"This sign-in link has expired or was already used. Sign in again."}"#)
        }
        let account = NaviAccount(cloud: stubTransport(host, tokens: MemoryTokenStore()), defaults: scratchDefaults("acct-badcode"))
        account.handle(url: URL(string: "navi://auth/callback?code=stale")!)
        for _ in 0..<100 where account.isSigningIn { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!account.isSignedIn && !account.isSigningIn)
        #expect(account.lastError == "Couldn't sign you in. This sign-in link has expired or was already used. Sign in again.")
    }

    @Test func deleteAccountSignsOutAndClearsEverything() async throws {
        let host = "acct-delete.test"
        StubProtocol.install(host: host) { req in
            #expect(req.httpMethod == "DELETE" && req.url!.path == "/v1/account")
            return StubProtocol.Reply(status: 204, body: Data())
        }
        let d = scratchDefaults("acct-delete")
        let tokens = MemoryTokenStore(access: "acc-1", refresh: "ref-1")
        let account = try signedInAccount(host, config: nil, defaults: d, tokens: tokens)
        let erased = Flag()
        // Wired to PrivacyData.deleteAllLocalData() by default; never erase this Mac in a test.
        #expect(account.canEraseLocalData)
        let real = NaviAccount.eraseLocalData
        NaviAccount.eraseLocalData = { erased.set(true) }
        defer { NaviAccount.eraseLocalData = real }
        let ok = await account.deleteAccount(alsoEraseLocalData: true)
        #expect(ok && erased.value)
        #expect(!account.isSignedIn && account.info == nil)
        #expect(tokens.accessToken == nil && tokens.refreshToken == nil)
        #expect(d.data(forKey: NaviAccount.snapshotKey) == nil)
        #expect(account.toast == "Your Navi account and this Mac's Navi data were deleted.")
        #expect(StubProtocol.requests(host: host).last?.value(forHTTPHeaderField: "Authorization") == "Bearer acc-1")
    }

    @Test func failedDeleteKeepsTheAccount() async throws {
        let host = "acct-delete-fail.test"
        StubProtocol.install(host: host) { _ in reply(500, #"{"error":"internal"}"#) }
        let d = scratchDefaults("acct-delete-fail")
        let account = try signedInAccount(host, config: nil, defaults: d)
        let ok = await account.deleteAccount(alsoEraseLocalData: false)
        #expect(!ok && account.isSignedIn)
        #expect(account.lastError == "Couldn't delete your account. Navi is having trouble right now. Try again in a moment.")
    }

    @Test func exportIsPrettyJSONWithADatedName() throws {
        let pretty = NaviAccount.prettyJSON(Data(#"{"b":1,"a":{"c":"https://x"}}"#.utf8))
        let text = try #require(String(data: pretty, encoding: .utf8))
        #expect(text.contains("\n") && text.contains("\"https://x\"") && text.firstIndex(of: "a")! < text.firstIndex(of: "b")!)
        #expect(NaviAccount.prettyJSON(Data("not json".utf8)) == Data("not json".utf8))
        let day = LenientDate.parse("2026-10-01T12:00:00Z")!
        #expect(NaviAccount.exportFileName(now: day).hasPrefix("Navi account data 2026-10-0"))
        #expect(NaviAccount.exportFileName(now: day).hasSuffix(".json"))
    }

    @Test func supportMailCarriesTheAccount() {
        let url = NaviLinks.supportMail(subject: "My Navi account is disabled", account: "liam@example.com")
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:support@navi.app?subject=My%20Navi%20account%20is%20disabled"))
        #expect(url.absoluteString.contains("liam@example.com"))
    }
}

// MARK: - Live, against `cloud/` running locally (opt-in)

/// `cd cloud && MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev npm run dev`, then
/// `TEST_RUNNER_NAVI_LIVE_CLOUD=http://localhost:3100 scripts/test.sh build/DerivedData-x`.
/// Uses an in-memory session and a scratch defaults suite: nothing of the installed app is touched.
@MainActor
struct LiveCloudAccountTests {
    nonisolated static let base = ProcessInfo.processInfo.environment["NAVI_LIVE_CLOUD"].flatMap(URL.init(string:))

    private func devLogin(_ base: URL, email: String) async throws -> (String, String) {
        var req = URLRequest(url: base.appendingPathComponent("auth/dev-login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ProcessInfo.processInfo.environment["NAVI_LIVE_DEV_SECRET"] ?? "dev", forHTTPHeaderField: "x-dev-login-secret")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        let (data, _) = try await URLSession.shared.data(for: req)
        let t = try CloudTransport.decodeTokens(data)
        return (t.accessToken, try #require(t.refreshToken))
    }

    @Test(.enabled(if: base != nil)) func signInRefreshAndSignOutAgainstTheLocalCloud() async throws {
        let base = try #require(Self.base)
        // 1. A bad one-time code: plain-words failure, still signed out.
        let tokens = MemoryTokenStore()
        let cloud = CloudTransport(baseURL: base, tokens: tokens)
        let account = NaviAccount(cloud: cloud, defaults: scratchDefaults("live"))
        account.handle(url: URL(string: "navi://auth/callback?code=not-a-real-code")!)
        for _ in 0..<200 where account.isSigningIn { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!account.isSignedIn)
        #expect(account.lastError?.hasPrefix("Couldn't sign you in.") == true)
        // 2. The error callback.
        account.handle(url: URL(string: "navi://auth/callback?error=sign_in_failed&message=Link%20expired")!)
        #expect(account.lastError == "Couldn't sign you in: link expired. Try again.")

        // 3. A real session (dev-login stands in for the browser), then /v1/me.
        let (access, refresh) = try await devLogin(base, email: "live-\(UUID().uuidString.prefix(8))@example.com")
        tokens.store(access: access, refresh: refresh, expiresAt: nil)
        let signedIn = NaviAccount(cloud: cloud, defaults: scratchDefaults("live2"))
        #expect(signedIn.isSignedIn)
        await signedIn.refreshMe(reason: "manual")
        #expect(signedIn.lastError == nil)
        #expect(signedIn.info?.user.email.hasPrefix("live-") == true)
        #expect(signedIn.trialDaysLeft != nil)                     // new accounts start a Pro trial
        print("live /v1/me: \(signedIn.planLabel) · \(signedIn.answersLine) · \(signedIn.tasksLine) · config \(String(describing: signedIn.info?.config))")

        // 4. A 401 refreshes once and retries.
        tokens.store(access: "expired-garbage", refresh: refresh, expiresAt: nil)
        await signedIn.refreshMe(reason: "manual")
        #expect(signedIn.isSignedIn && signedIn.lastError == nil)
        #expect(tokens.accessToken != "expired-garbage")

        // 5. The refresh token is no good any more: clean signed-out state.
        tokens.store(access: "expired-garbage", refresh: "revoked-\(UUID().uuidString)", expiresAt: nil)
        await signedIn.refreshMe(reason: "manual")
        #expect(!signedIn.isSignedIn && signedIn.info == nil)
        #expect(tokens.accessToken == nil && tokens.refreshToken == nil)
        #expect(signedIn.lastError == "You were signed out. Sign in again to keep using answers and tasks.")
    }
}
