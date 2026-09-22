import AppKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Settings

extension NaviSettings {
    /// Where Navi looks for `appcast.json` (written by scripts/gen-appcast.sh, hosted next to
    /// the DMG — docs/RELEASE.md). Override for a local test feed:
    /// `defaults write com.liamcarlin.navi updateFeedURL http://localhost:8000/appcast.json`.
    nonisolated static var updateFeedURL: URL {
        if let s = UserDefaults.standard.string(forKey: "updateFeedURL"), let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: "https://navi.app/appcast.json")!
    }
    /// `defaults write com.liamcarlin.navi updateChecksEnabled -bool NO` turns the daily check off.
    nonisolated static var updateChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: "updateChecksEnabled") as? Bool ?? true
    }
}

// MARK: - Appcast

/// `appcast.json` exactly as scripts/gen-appcast.sh writes it.
struct Appcast: Codable, Equatable {
    var version: String        // CFBundleShortVersionString of the release, e.g. "0.2.0"
    var build: String          // CFBundleVersion
    var url: URL               // the DMG
    var sha256: String         // hex SHA-256 of the DMG
    var ed25519: String        // base64 raw 64-byte signature over the DMG (openssl pkeyutl -rawin)
    var notes: String?         // release notes, plain text
    var minOS: String?         // lowest macOS that can run it, e.g. "26.0"
    var published: String?     // ISO-8601
}

/// Dotted numeric versions with an optional prerelease tag: `1.2` == `1.2.0`,
/// `1.0.0-beta.1` < `1.0.0`, a leading `v` and `+build` metadata are ignored.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            s = String(s[..<dash])
        }
        guard !s.isEmpty else { return nil }
        var nums: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        numbers = nums
        prerelease = pre
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// Components zero-padded to a common length, so `1.2` and `1.2.0` compare equal.
    private static func padded(_ a: SemanticVersion, _ b: SemanticVersion) -> ([Int], [Int]) {
        let n = max(a.numbers.count, b.numbers.count)
        return (a.numbers + Array(repeating: 0, count: n - a.numbers.count),
                b.numbers + Array(repeating: 0, count: n - b.numbers.count))
    }

    static func == (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let (x, y) = padded(a, b)
        return x == y && a.prerelease == b.prerelease
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let (xs, ys) = padded(a, b)
        for (x, y) in zip(xs, ys) where x != y { return x < y }
        // Equal numbers: a release outranks any prerelease; prereleases compare identifier-wise.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            for (p, q) in zip(a.prerelease, b.prerelease) where p != q {
                switch (Int(p), Int(q)) {
                case let (x?, y?): return x < y
                case (.some, .none): return true      // numeric identifiers sort before alphanumeric
                case (.none, .some): return false
                default: return p < q
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }
}

// MARK: - Verification

enum UpdateVerifier {
    /// Navi's appcast signing key (ed25519, raw 32 bytes, base64). The matching private key
    /// lives outside the repo on the release Mac (`~/.config/navi-release/update-key.pem`);
    /// docs/RELEASE.md covers generation and rotation.
    static let publicKeyBase64 = "74vKC4FZpwW1wQHwMaSPG/HiW67QDBvOz07SZvOKwi0="

    enum Failure: Error, Equatable, LocalizedError {
        case digestMismatch, badSignature, badPublicKey
        var errorDescription: String? {
            switch self {
            case .digestMismatch: return "The download is damaged (SHA-256 mismatch)."
            case .badSignature: return "The download is not signed by Navi."
            case .badPublicKey: return "The built-in update key is invalid."
            }
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Both checks must pass: the digest proves the bytes are the ones the appcast named,
    /// the signature proves the appcast author held Navi's private key.
    static func verify(_ data: Data, sha256: String, signatureBase64: String, publicKeyBase64: String = publicKeyBase64) throws {
        guard sha256Hex(data) == sha256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { throw Failure.digestMismatch }
        guard let keyBytes = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { throw Failure.badPublicKey }
        guard let sig = Data(base64Encoded: signatureBase64), key.isValidSignature(sig, for: data) else { throw Failure.badSignature }
    }
}

enum UpdateError: LocalizedError {
    case http(Int), badVersion(String), noAppInImage, notWritable(String), tool(String)
    var errorDescription: String? {
        switch self {
        case .http(let code): return "The update server answered \(code)."
        case .badVersion(let v): return "The update feed has an unreadable version (\(v))."
        case .noAppInImage: return "The downloaded disk image does not contain Navi.app."
        case .notWritable(let p): return "Navi cannot replace itself at \(p)."
        case .tool(let m): return m
        }
    }
}

// MARK: - Updater

/// Dependency-free in-app updates: fetch `appcast.json`, compare versions, download the
/// DMG, verify SHA-256 + ed25519, mount it, stage `Navi.app`, then hand off to a detached
/// shell script that waits for this process to quit, swaps the bundle and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, available, downloading(Double), installing, upToDate, failed(String)
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var pending: Appcast?

    private var timer: Timer?
    private var window: NSWindow?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    /// 30 s after launch, then every 24 h. Silent unless an update is available.
    func start() {
        guard NaviSettings.updateChecksEnabled, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkForUpdates(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdates(userInitiated: false) }
        }
    }

    /// Menu bar → "Check for Updates…" (`userInitiated`): also reports "up to date" and errors.
    func checkForUpdates(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        case .available: if userInitiated { showWindow() }; return
        default: break
        }
        state = .checking
        Task { await check(userInitiated: userInitiated) }
    }

    /// Pure decision, unit-tested: offer `remote` when it is newer than `local` and the user
    /// has not skipped exactly that version (a manual check ignores the skip).
    nonisolated static func shouldOffer(remote: String, local: String, skipped: String?, userInitiated: Bool) -> Bool {
        guard let r = SemanticVersion(remote), let l = SemanticVersion(local), r > l else { return false }
        return userInitiated || skipped != remote
    }

    nonisolated static func osSatisfies(_ minOS: String?) -> Bool {
        guard let minOS, let need = SemanticVersion(minOS) else { return true }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return SemanticVersion("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)").map { $0 >= need } ?? true
    }

    private func check(userInitiated: Bool) async {
        do {
            let appcast = try await fetchAppcast()
            guard SemanticVersion(appcast.version) != nil else { throw UpdateError.badVersion(appcast.version) }
            let skipped = UserDefaults.standard.string(forKey: "updateSkippedVersion")
            if Self.shouldOffer(remote: appcast.version, local: Self.currentVersion, skipped: skipped, userInitiated: userInitiated) {
                guard Self.osSatisfies(appcast.minOS) else {
                    state = .upToDate
                    if userInitiated { alert("Navi \(appcast.version) needs macOS \(appcast.minOS ?? "")", "You're on an older macOS; Navi \(Self.currentVersion) stays installed.") }
                    return
                }
                pending = appcast
                state = .available
                Log.app.info("update available: \(appcast.version) (\(appcast.build))")
                showWindow()
            } else {
                state = .upToDate
                Log.app.info("update check: up to date (\(Self.currentVersion), feed \(appcast.version))")
                if userInitiated { alert("You're up to date", "Navi \(Self.currentVersion) is the latest version.") }
            }
        } catch {
            state = .failed(error.localizedDescription)
            Log.app.error("update check failed: \(error.localizedDescription)")
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    func fetchAppcast() async throws -> Appcast {
        var req = URLRequest(url: NaviSettings.updateFeedURL)
        req.setValue("Navi/\(Self.currentVersion) (\(Self.currentBuild); macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw UpdateError.http(http.statusCode) }
        return try JSONDecoder().decode(Appcast.self, from: data)
    }

    // MARK: Install

    func installPending() {
        guard let appcast = pending else { return }
        Task { await install(appcast) }
    }

    func skipPending() {
        if let v = pending?.version { UserDefaults.standard.set(v, forKey: "updateSkippedVersion") }
        pending = nil; state = .idle; closeWindow()
    }

    func later() { state = .idle; closeWindow() }

    private func install(_ appcast: Appcast) async {
        state = .downloading(0)
        do {
            let dmg = try await download(appcast.url)
            defer { try? FileManager.default.removeItem(at: dmg) }
            state = .installing
            let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
            try UpdateVerifier.verify(data, sha256: appcast.sha256, signatureBase64: appcast.ed25519)
            let staged = try await Task.detached { try Updater.stageApp(fromDMG: dmg) }.value
            try swapAndRelaunch(with: staged)
        } catch {
            state = .failed(error.localizedDescription)
            Log.app.error("update install failed: \(error.localizedDescription)")
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let progress = DownloadProgress { [weak self] p in Task { @MainActor in self?.state = .downloading(p) } }
        let (tmp, resp) = try await session.download(from: url, delegate: progress)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw UpdateError.http(http.statusCode) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Navi-update-\(UUID().uuidString.prefix(8)).dmg")
        try FileManager.default.moveItem(at: tmp, to: dest)   // the temp file is gone once this call returns
        return dest
    }

    /// `hdiutil attach` → copy the app out → `detach`. Runs off the main actor.
    nonisolated static func stageApp(fromDMG dmg: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let mount = tmp.appendingPathComponent("navi-update-mount-\(UUID().uuidString.prefix(8))")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let entries = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInImage }
        let staging = tmp.appendingPathComponent("navi-update-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", [app.path, staged.path])
        // The DMG arrived quarantined; the (notarized) app inside was verified above and the
        // user asked to install it — drop the flag so the relaunch does not stall on a prompt.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// The classic Sparkle-free swap: a detached `/bin/sh` waits for this pid to exit,
    /// moves the old bundle aside, copies the new one in, re-registers it and relaunches.
    private func swapAndRelaunch(with staged: URL) throws {
        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), FileManager.default.isWritableFile(atPath: dest.path) else {
            state = .failed(UpdateError.notWritable(dest.path).localizedDescription)
            let a = NSAlert()
            a.messageText = "Navi can't replace itself in \(parent.path)"
            a.informativeText = "The new version is ready. Drag it over the current Navi.app to finish updating."
            a.addButton(withTitle: "Show in Finder"); a.addButton(withTitle: "Cancel")
            a.window.level = .floating
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([staged]) }
            return
        }
        let script = """
        #!/bin/sh
        # Navi updater: wait for the running app to quit, swap the bundle, relaunch.
        while kill -0 "$NAVI_PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$NAVI_DEST.old"
        if mv "$NAVI_DEST" "$NAVI_DEST.old" && ditto "$NAVI_STAGED" "$NAVI_DEST"; then
          rm -rf "$NAVI_DEST.old" "$(dirname "$NAVI_STAGED")"
        else
          rm -rf "$NAVI_DEST"; mv "$NAVI_DEST.old" "$NAVI_DEST" 2>/dev/null
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$NAVI_DEST" >/dev/null 2>&1
        open "$NAVI_DEST"
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("navi-update-swap-\(UUID().uuidString.prefix(8)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        p.environment = ["NAVI_PID": String(ProcessInfo.processInfo.processIdentifier), "NAVI_DEST": dest.path,
                         "NAVI_STAGED": staged.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        Log.app.info("update staged at \(staged.path); relaunching")
        closeWindow()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let tail = String(data: data, encoding: .utf8)?.split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            throw UpdateError.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(p.terminationStatus)): \(tail)")
        }
    }

    // MARK: UI

    private func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingController(rootView: UpdateView(updater: self))
        let w = NSWindow(contentViewController: host)
        w.title = "Software Update"
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Progress relay for `URLSession.download(from:delegate:)`.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let report: (Double) -> Void
    init(report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The non-modal "Navi X is available" window.
struct UpdateView: View {
    @ObservedObject var updater: Updater

    private var busy: Bool {
        switch updater.state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Navi \(updater.pending?.version ?? "") is available").font(.headline)
                    Text("You have Navi \(Updater.currentVersion). Would you like to install it now?")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let notes = updater.pending?.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(10)
                .frame(height: 150)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            switch updater.state {
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading…").font(.caption) }
            case .installing:
                ProgressView { Text("Verifying and installing…").font(.caption) }
            case .failed(let e):
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
            HStack {
                Button("Skip This Version") { updater.skipPending() }.disabled(busy)
                Spacer()
                Button("Later") { updater.later() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Install Update") { updater.installPending() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
