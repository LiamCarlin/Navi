import Testing
import Foundation
@testable import Navi

extension Trait where Self == ConditionTrait {
    /// For the few tests that genuinely need the network. Off unless the run opts in:
    /// `NAVI_TEST_NETWORK=1 scripts/test.sh` (keys come from the same shell's env vars).
    static var needsNetwork: Self {
        .enabled(if: TestHost.allowsNetwork, "network tests are opt-in: NAVI_TEST_NETWORK=1 scripts/test.sh")
    }
}

/// The suite runs hosted inside Navi.app. These pin that the host stays inert:
/// no capture, no services, no real settings / Keychain / data paths, no network.
@Suite struct TestHostTests {
    @Test func detectsTheTestHost() {
        #expect(TestHost.isActive)
    }

    @MainActor @Test func hostStartsNoServices() throws {
        let app = try #require(AppDelegate.shared)
        #expect(app.services == nil)        // ⇒ no MemoryService / CaptureScheduler, router or agent
        #expect(app.hotKey == nil)
        #expect(app.panelController == nil)
        #expect(app.voice == nil)
    }

    @MainActor @Test func memoryServiceNeverCapturesUnderTests() {
        let settings = NaviSettings.shared
        let was = settings.memoryCaptureEnabled
        settings.memoryCaptureEnabled = true
        defer { settings.memoryCaptureEnabled = was }
        let memory = MemoryService(jev: JevClient(), claude: ClaudeClient())
        memory.start()
        #expect(!memory.status.isRunning)
        #expect(memory.vaultURL == nil)     // the store / vault / scheduler were never built
        memory.stop()
    }

    @MainActor @Test func settingsAndDataAreThrowaway() {
        #expect(UserDefaults.navi !== UserDefaults.standard)
        #expect(TestHost.defaultsSuite != "com.liamcarlin.navi")
        let scratch = TestHost.scratchDirectory.standardizedFileURL.path
        #expect(NaviSettings.dataDirectory.standardizedFileURL.path.hasPrefix(scratch))
        #expect(NaviSettings.shared.memoryVaultPath.hasPrefix(TestHost.scratchDirectory.path))
        #expect(!NaviSettings.shared.memoryVaultPath.hasPrefix(NSString(string: "~/Navi Vault").expandingTildeInPath))
        #expect(AgentExperience.defaultFileURL.standardizedFileURL.path.hasPrefix(scratch))
        // A write lands in the suite, not in com.liamcarlin.navi.
        let key = "testHostProbe.\(UUID().uuidString)"
        UserDefaults.navi.set(true, forKey: key)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        UserDefaults.navi.removeObject(forKey: key)
    }

    @Test func keychainIsInMemory() {
        #expect(Keychain.isInMemory)
        #expect(Keychain.loadState == .loaded)
    }

    @Test(.enabled(if: !TestHost.allowsNetwork)) func networkIsOffByDefault() async {
        let cfg = TestHost.guarded(.ephemeral)
        let session = URLSession(configuration: cfg)
        do {
            _ = try await session.data(from: URL(string: "https://api.typesafe.ai/v1/systemone")!)
            Issue.record("a request left the test host")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        // URLSession.shared too (registered by the test-host launch path).
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://example.com/")!)
            Issue.record("URLSession.shared reached the network")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    /// Live smoke test: one real Jev call. Needs `NAVI_TEST_NETWORK=1` and a Jev key in the env.
    @Test(.needsNetwork) func jevAnswersLive() async throws {
        let jev = JevClient()
        try #require(jev.isConfigured, "set TYPESAFE_API_KEY or AI_GATEWAY_API_KEY")
        let r = try await jev.ask(state: "[QUERY]\nopen maps", questions: ["is_app_launch": .noul(instructions: "Does the user want to open an app?")],
                                  cacheable: false)
        #expect((r.answers["is_app_launch"]?.noul ?? 0) > 0.5)
    }
}
