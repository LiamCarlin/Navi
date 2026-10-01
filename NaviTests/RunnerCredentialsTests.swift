import Testing
import Foundation
@testable import Navi

/// The browser runner's credentials: a signed-in user's runner holds no vendor key,
/// only the cloud URL + a short-lived bearer + the task's run (UltrafastBridge).
struct RunnerCredentialsTests {
    static let run = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let shell: [String: String] = [
        "PATH": "/usr/bin", "HOME": "/Users/x",
        "TYPESAFE_API_KEY": "ts-shell", "AI_GATEWAY_API_KEY": "gw-shell", "ANTHROPIC_API_KEY": "sk-shell",
        "ANTHROPIC_BASE_URL": "https://proxy.example", "TEXT_MODEL_API_KEY": "tm", "TEXT_MODEL_BASE_URL": "https://tm", "TEXT_MODEL": "m",
        "NAVI_JEV_TRANSPORT": "vercel",
    ]

    @Test func cloudCredentialsCarryNoVendorKey() {
        let env = UltrafastBridge.applying(.cloud(baseURL: URL(string: "https://api.navi.app/")!, token: "acc-1",
                                                  feature: .voice, runID: Self.run), to: Self.shell)
        #expect(env["NAVI_JEV_TRANSPORT"] == "navi")
        #expect(env["NAVI_CLOUD_URL"] == "https://api.navi.app")          // no trailing slash
        #expect(env["NAVI_CLOUD_TOKEN"] == "acc-1")
        #expect(env["NAVI_CLOUD_FEATURE"] == "voice")
        #expect(env["NAVI_CLOUD_RUN"] == "6f9619ff-8b86-d011-b42d-00c04fc964ff")   // as CloudTransport sends X-Navi-Run
        for k in UltrafastBridge.vendorVariables { #expect(env[k] == nil, "\(k) must not reach a cloud run") }
        #expect(env["PATH"] == "/usr/bin" && env["HOME"] == "/Users/x")
    }

    @Test func cloudKeepsALocalPortAndPath() {
        let env = UltrafastBridge.applying(.cloud(baseURL: URL(string: "http://127.0.0.1:3100")!, token: "t",
                                                  feature: .task, runID: Self.run), to: [:])
        #expect(env["NAVI_CLOUD_URL"] == "http://127.0.0.1:3100")
        #expect(env["NAVI_CLOUD_FEATURE"] == "task")
    }

    @Test func typesafeKeysClearAStaleCloudSession() {
        var base = Self.shell
        base["NAVI_CLOUD_TOKEN"] = "stale"; base["NAVI_CLOUD_URL"] = "https://api.navi.app"
        let env = UltrafastBridge.applying(.typesafe(key: "ts-key", anthropicKey: "sk-key"), to: base)
        #expect(env["TYPESAFE_API_KEY"] == "ts-key")
        #expect(env["ANTHROPIC_API_KEY"] == "sk-key")
        #expect(env["NAVI_JEV_TRANSPORT"] == nil)
        #expect(env["AI_GATEWAY_API_KEY"] == nil)
        for k in UltrafastBridge.cloudVariables { #expect(env[k] == nil) }
        // Developer escape hatches stay.
        #expect(env["ANTHROPIC_BASE_URL"] == "https://proxy.example" && env["TEXT_MODEL_API_KEY"] == "tm")
    }

    @Test func gatewayKeys() {
        let env = UltrafastBridge.applying(.vercelGateway(key: "gw-key", anthropicKey: nil), to: ["ANTHROPIC_API_KEY": "sk-shell"])
        #expect(env["AI_GATEWAY_API_KEY"] == "gw-key")
        #expect(env["NAVI_JEV_TRANSPORT"] == "vercel")
        #expect(env["TYPESAFE_API_KEY"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == "sk-shell")      // no Keychain key: the shell's stays
    }

    // MARK: Token lifetime

    @Test func refreshOnlyWhenTheTokenWouldLapseDuringARun() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!CloudTransport.needsRefresh(expiresAt: now.addingTimeInterval(3600), validFor: 1200, now: now))
        #expect(CloudTransport.needsRefresh(expiresAt: now.addingTimeInterval(600), validFor: 1200, now: now))
        #expect(CloudTransport.needsRefresh(expiresAt: now.addingTimeInterval(-5), validFor: 1200, now: now))
        #expect(!CloudTransport.needsRefresh(expiresAt: nil, validFor: 1200, now: now))
    }

    @Test func aFreshTokenIsHandedOverWithoutANetworkCall() async {
        let host = "runner-fresh.test"
        StubProtocol.install(host: host) { _ in StubProtocol.json(500, ["error": "unexpected"]) }
        let tokens = MemoryTokenStore(access: "acc-long", refresh: "ref-1", expiresAt: Date().addingTimeInterval(3000))
        let cloud = CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
        let token = await cloud.accessToken(validFor: 1200)
        #expect(token == "acc-long")
        #expect(StubProtocol.requests(host: host).isEmpty)
    }

    @Test func aTokenAboutToLapseIsRefreshedFirst() async {
        let host = "runner-refresh.test"
        StubProtocol.install(host: host) { req in
            #expect(req.url?.path == "/auth/refresh")
            return StubProtocol.json(200, ["accessToken": "acc-new", "refreshToken": "ref-2", "expiresAt": "2099-01-01T00:00:00Z"])
        }
        let tokens = MemoryTokenStore(access: "acc-old", refresh: "ref-1", expiresAt: Date().addingTimeInterval(300))
        let cloud = CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
        let token = await cloud.accessToken(validFor: 1200)
        #expect(token == "acc-new")
        #expect(tokens.accessToken == "acc-new" && tokens.refreshToken == "ref-2")
        let body = (try? JSONSerialization.jsonObject(with: StubProtocol.requests(host: host).first?.httpBody ?? Data())) as? [String: Any]
        #expect(body?["refreshToken"] as? String == "ref-1")
    }

    @Test func aNetworkBlipKeepsAStillValidToken() async {
        let host = "runner-blip.test"
        StubProtocol.install(host: host) { _ in StubProtocol.json(502, ["error": "bad gateway"]) }
        let tokens = MemoryTokenStore(access: "acc-old", refresh: "ref-1", expiresAt: Date().addingTimeInterval(300))
        let cloud = CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
        #expect(await cloud.accessToken(validFor: 1200) == "acc-old")
        #expect(tokens.refreshToken == "ref-1")
    }

    @Test func aRevokedSessionYieldsNoToken() async {
        let host = "runner-revoked.test"
        StubProtocol.install(host: host) { _ in StubProtocol.json(401, ["error": "unauthenticated"]) }
        let tokens = MemoryTokenStore(access: "acc-old", refresh: "ref-1", expiresAt: Date().addingTimeInterval(-10))
        let cloud = CloudTransport(session: StubProtocol.session(), baseURL: URL(string: "http://\(host)")!, tokens: tokens)
        #expect(await cloud.accessToken(validFor: 1200) == nil)
        #expect(tokens.accessToken == nil && tokens.refreshToken == nil)       // signed out locally
    }

    // MARK: Cloud base URL from the build

    @Test func cloudBaseURLComesFromInfoPlistWithFallback() {
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: nil) == CloudTransport.fallbackBaseURL)
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: "  ") == CloudTransport.fallbackBaseURL)
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: "not a url") == CloudTransport.fallbackBaseURL)
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: "ftp://api.example.com") == CloudTransport.fallbackBaseURL)
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: "https://api.example.com/") == "https://api.example.com")
        #expect(CloudTransport.resolveDefaultBaseURL(infoPlist: "http://127.0.0.1:3100") == "http://127.0.0.1:3100")
        let plist = Bundle.main.object(forInfoDictionaryKey: "NaviCloudBaseURL") as? String
        #expect(CloudTransport.defaultBaseURL == CloudTransport.resolveDefaultBaseURL(infoPlist: plist))
    }

    // MARK: Runner errors

    @Test func proxyRefusalsReadAsNavi() {
        let quota = UltrafastBridge.runnerErrorMessage(["event": "error", "message": "x", "code": "quota_exceeded",
                                                        "feature": "task", "tier": "free", "resetsAt": "2026-10-02T00:00:00Z"])
        #expect(quota == NaviError.quotaExceeded(feature: "task", tier: "free",
                                                 resetsAt: ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")).localizedDescription)
        #expect(UltrafastBridge.runnerErrorMessage(["code": "signed_out", "message": "x"]) == NaviError.signedOut.localizedDescription)
        #expect(UltrafastBridge.runnerErrorMessage(["code": "not_entitled", "feature": "voice", "tier": "free"])
                == NaviError.notEntitled(feature: "voice", tier: "free").localizedDescription)
        #expect(UltrafastBridge.runnerErrorMessage(["message": "Could not open the browser tab: boom"]) == "Could not open the browser tab: boom")
        #expect(!UltrafastBridge.runnerErrorMessage([:]).isEmpty)
    }
}
