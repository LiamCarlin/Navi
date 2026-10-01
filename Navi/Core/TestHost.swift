import Foundation

/// The unit tests run hosted inside a Debug Navi.app (`TEST_HOST` in project.yml),
/// so the app really launches under them. In that mode it must not touch the
/// user's data or the network:
///
/// - `AppDelegate` starts nothing: no screen memory, voice, hot keys, Chrome
///   approval monitor, account refresh, update check or runner warm-up.
/// - Settings live in a throwaway UserDefaults suite (`UserDefaults.navi`), wiped
///   at launch and removed at exit — never `com.liamcarlin.navi`.
/// - `Keychain` is an empty in-memory store (env vars still override).
/// - Local data (memory.sqlite, the vault, agent experience) goes to a scratch
///   directory under the temp dir.
/// - Model/cloud/update sessions fail every non-loopback request, unless
///   `NAVI_TEST_NETWORK=1` (`NAVI_TEST_NETWORK=1 scripts/test.sh`); tests that
///   genuinely need the network declare `.needsNetwork`.
enum TestHost {
    /// True when this process is hosting XCTest / Swift Testing.
    static let isActive: Bool = {
        let info = ProcessInfo.processInfo
        let env = info.environment
        if env["NAVI_TEST_HOST"] == "1" || info.arguments.contains("-NaviTestHost") { return true }
        if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains(where: { env[$0] != nil }) {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Tests may reach the network (`NAVI_TEST_NETWORK=1`). Off by default.
    static let allowsNetwork: Bool = ProcessInfo.processInfo.environment["NAVI_TEST_NETWORK"] == "1"

    // MARK: Settings

    /// One suite per test-host process, so concurrent runs from other checkouts don't collide.
    static let defaultsSuite = "com.liamcarlin.navi.testhost.\(ProcessInfo.processInfo.processIdentifier)"

    static let defaults: UserDefaults = {
        guard isActive, let d = UserDefaults(suiteName: defaultsSuite) else { return .standard }
        d.removePersistentDomain(forName: defaultsSuite)
        registerCleanup()
        return d
    }()

    // MARK: Local data

    /// Stand-in for ~/Library/Application Support/Navi (and the vault's parent) under tests.
    static let scratchDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaviTestHost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registerCleanup()
        return dir
    }()

    private static let cleanupOnce: Void = {
        sweepStale()
        atexit {
            UserDefaults.standard.removePersistentDomain(forName: TestHost.defaultsSuite)
            TestHost.removeLeftovers(pid: ProcessInfo.processInfo.processIdentifier)
        }
    }()

    private static let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    /// The suite plist and scratch dir of one test-host process.
    private static func removeLeftovers(pid: Int32) {
        let fm = FileManager.default
        try? fm.removeItem(at: preferencesDirectory.appendingPathComponent("com.liamcarlin.navi.testhost.\(pid).plist"))
        try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("NaviTestHost-\(pid)"))
    }

    /// A host that crashed never ran its atexit: clear what dead test hosts left behind.
    private static func sweepStale() {
        let fm = FileManager.default
        let me = ProcessInfo.processInfo.processIdentifier
        let names = ((try? fm.contentsOfDirectory(atPath: preferencesDirectory.path)) ?? [])
            + ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [])
        for name in names {
            let digits: Substring
            if name.hasPrefix("com.liamcarlin.navi.testhost."), name.hasSuffix(".plist") {
                digits = name.dropFirst("com.liamcarlin.navi.testhost.".count).dropLast(".plist".count)
            } else if name.hasPrefix("NaviTestHost-") {
                digits = name.dropFirst("NaviTestHost-".count)
            } else { continue }
            guard let pid = Int32(digits), pid != me, kill(pid, 0) != 0, errno == ESRCH else { continue }
            removeLeftovers(pid: pid)
        }
    }

    private static func registerCleanup() { _ = cleanupOnce }

    // MARK: Network

    /// Applied to every URLSession Navi builds for models, the cloud and updates.
    static func guarded(_ cfg: URLSessionConfiguration) -> URLSessionConfiguration {
        if isActive && !allowsNetwork {
            cfg.protocolClasses = [OfflineURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        return cfg
    }

    /// Covers `URLSession.shared` too. Called once by the test-host launch path.
    static func installNetworkGuard() {
        guard isActive && !allowsNetwork else { return }
        URLProtocol.registerClass(OfflineURLProtocol.self)
    }

    /// Fails any request that would leave the Mac. Loopback stays open for mock servers.
    final class OfflineURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            guard let host = request.url?.host?.lowercased() else { return false }
            return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let error = URLError(.notConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "Network is off in the test host (NAVI_TEST_NETWORK=1 to allow): \(request.url?.host ?? "?")",
            ])
            client?.urlProtocol(self, didFailWithError: error)
        }

        override func stopLoading() {}
    }
}

extension UserDefaults {
    /// Navi's settings store: `.standard` in the app, a throwaway suite under the test host.
    /// Use this everywhere instead of `.standard`.
    static var navi: UserDefaults { TestHost.defaults }
}
