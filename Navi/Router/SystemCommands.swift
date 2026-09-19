import Foundation
import AppKit

/// Instant macOS system actions ("sleep", "dark mode", "wifi off", "quit slack").
/// Matching is pure (`matches(_:)`); execution uses `Process` for shell tools and
/// `NSAppleScript` for System Events / Finder.
enum SystemCommands {

    /// A matched command, ready to be turned into a row.
    struct Command: Sendable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let score: Double
        let action: Action
    }

    enum Action: Sendable, Equatable {
        case sleep, lock, restart, shutDown, logOut
        case darkMode(Bool?)          // true = dark, false = light, nil = toggle
        case emptyTrash
        case mute(Bool)               // true = mute
        case volume(Int)
        case volumeStep(Int)
        case wifi(Bool)
        case bluetooth
        case screenshot
        case keepAwake(Bool?)         // nil = toggle
        case eject
        case hideOthers
        case quitApp(String, force: Bool)
        case confirmRequired(String)  // tells the user to append " now"
        case showDesktop
        case doNotDisturb
    }

    private struct Spec {
        let phrases: [String]
        let title: String
        let subtitle: String
        let icon: String
        let action: Action
        let destructive: Bool
    }

    private static let specs: [Spec] = [
        Spec(phrases: ["sleep", "go to sleep", "sleep mac", "sleep now"], title: "Sleep", subtitle: "Put this Mac to sleep", icon: "moon.zzz.fill", action: .sleep, destructive: false),
        Spec(phrases: ["lock", "lock screen", "lock mac", "lock the screen"], title: "Lock Screen", subtitle: "Lock this Mac", icon: "lock.fill", action: .lock, destructive: false),
        Spec(phrases: ["restart", "reboot", "restart mac"], title: "Restart", subtitle: "Restart this Mac", icon: "arrow.clockwise.circle.fill", action: .restart, destructive: true),
        Spec(phrases: ["shut down", "shutdown", "power off", "turn off"], title: "Shut Down", subtitle: "Shut down this Mac", icon: "power.circle.fill", action: .shutDown, destructive: true),
        Spec(phrases: ["log out", "logout", "sign out"], title: "Log Out", subtitle: "Log out of this Mac", icon: "person.crop.circle.badge.xmark", action: .logOut, destructive: true),
        Spec(phrases: ["dark mode", "dark", "enable dark mode", "dark mode on"], title: "Dark Mode", subtitle: "Switch appearance to dark", icon: "moon.fill", action: .darkMode(true), destructive: false),
        Spec(phrases: ["light mode", "light", "enable light mode", "dark mode off"], title: "Light Mode", subtitle: "Switch appearance to light", icon: "sun.max.fill", action: .darkMode(false), destructive: false),
        Spec(phrases: ["toggle dark mode", "toggle appearance", "toggle theme", "switch appearance", "appearance"], title: "Toggle Dark Mode", subtitle: "Switch between light and dark appearance", icon: "circle.lefthalf.filled", action: .darkMode(nil), destructive: false),
        Spec(phrases: ["empty trash", "empty the trash", "trash empty"], title: "Empty Trash", subtitle: "Permanently delete items in the Trash", icon: "trash.fill", action: .emptyTrash, destructive: false),
        Spec(phrases: ["mute", "mute volume", "silence"], title: "Mute", subtitle: "Mute system audio", icon: "speaker.slash.fill", action: .mute(true), destructive: false),
        Spec(phrases: ["unmute", "unmute volume"], title: "Unmute", subtitle: "Unmute system audio", icon: "speaker.wave.2.fill", action: .mute(false), destructive: false),
        Spec(phrases: ["volume up", "louder"], title: "Volume Up", subtitle: "Increase volume by 10", icon: "speaker.plus.fill", action: .volumeStep(10), destructive: false),
        Spec(phrases: ["volume down", "quieter"], title: "Volume Down", subtitle: "Decrease volume by 10", icon: "speaker.minus.fill", action: .volumeStep(-10), destructive: false),
        Spec(phrases: ["wifi on", "wi-fi on", "turn on wifi", "enable wifi"], title: "Wi-Fi On", subtitle: "Turn Wi-Fi on", icon: "wifi", action: .wifi(true), destructive: false),
        Spec(phrases: ["wifi off", "wi-fi off", "turn off wifi", "disable wifi"], title: "Wi-Fi Off", subtitle: "Turn Wi-Fi off", icon: "wifi.slash", action: .wifi(false), destructive: false),
        Spec(phrases: ["bluetooth", "bluetooth settings", "bt"], title: "Bluetooth", subtitle: "Open Bluetooth settings", icon: "bolt.horizontal.circle", action: .bluetooth, destructive: false),
        Spec(phrases: ["screenshot", "take screenshot", "take a screenshot", "capture screen", "screen capture"], title: "Screenshot", subtitle: "Capture a region to the Desktop", icon: "camera.viewfinder", action: .screenshot, destructive: false),
        Spec(phrases: ["caffeinate", "keep awake", "stay awake", "prevent sleep", "no sleep"], title: "Keep Awake", subtitle: "Toggle caffeinate (prevent sleep)", icon: "cup.and.saucer.fill", action: .keepAwake(nil), destructive: false),
        Spec(phrases: ["decaffeinate", "keep awake off", "stop caffeinate", "allow sleep"], title: "Allow Sleep", subtitle: "Stop caffeinate", icon: "cup.and.saucer", action: .keepAwake(false), destructive: false),
        Spec(phrases: ["eject", "eject all", "eject disks", "unmount"], title: "Eject All", subtitle: "Eject all external disks", icon: "eject.fill", action: .eject, destructive: false),
        Spec(phrases: ["hide others", "hide other apps", "hide all others"], title: "Hide Others", subtitle: "Hide all apps except the current one", icon: "eye.slash.fill", action: .hideOthers, destructive: false),
        Spec(phrases: ["show desktop", "desktop"], title: "Show Desktop", subtitle: "Hide all windows", icon: "menubar.dock.rectangle", action: .showDesktop, destructive: false),
        Spec(phrases: ["do not disturb", "dnd", "focus"], title: "Do Not Disturb", subtitle: "Open Focus settings", icon: "moon.circle.fill", action: .doNotDisturb, destructive: false),
    ]

    private static let volumeRegex = try! NSRegularExpression(pattern: #"^(?:set\s+)?volume\s+(?:to\s+)?(\d{1,3})%?$"#)
    private static let quitRegex = try! NSRegularExpression(pattern: #"^(quit|close|kill|force quit|force-quit)\s+(.+)$"#)

    // MARK: - Matching (pure)

    static func matches(_ query: String) -> [Command] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return [] }
        let wantsNow = raw.hasSuffix(" now")
        let q = wantsNow ? String(raw.dropLast(4)).trimmingCharacters(in: .whitespaces) : raw
        var out: [Command] = []
        let full = NSRange(q.startIndex..., in: q)

        if let m = volumeRegex.firstMatch(in: q, range: full), let r = Range(m.range(at: 1), in: q),
           let n = Int(q[r]), (0...100).contains(n) {
            out.append(Command(id: "sys:volume", title: "Volume \(n)%", subtitle: "Set output volume to \(n)%",
                               icon: "speaker.wave.2.fill", score: 1.0, action: .volume(n)))
        }
        if let m = quitRegex.firstMatch(in: q, range: full),
           let verbR = Range(m.range(at: 1), in: q), let appR = Range(m.range(at: 2), in: q) {
            let verb = String(q[verbR]), app = String(q[appR]).trimmingCharacters(in: .whitespaces)
            let force = verb.contains("kill") || verb.contains("force")
            if !app.isEmpty {
                out.append(Command(id: "sys:quit:\(app)", title: "\(force ? "Force Quit" : "Quit") \(app.capitalized)",
                                   subtitle: force ? "Force-terminate the running app" : "Ask the app to quit",
                                   icon: "xmark.circle.fill", score: 0.92, action: .quitApp(app, force: force)))
            }
        }

        for spec in specs {
            var best = 0.0
            for p in spec.phrases {
                if q == p { best = max(best, 1.0) }
                else if q.count >= 3, p.hasPrefix(q) { best = max(best, 0.75) }
                else if q.count >= 5, p.contains(q) || q.contains(p) { best = max(best, 0.6) }
            }
            guard best > 0 else { continue }
            let action: Action
            var subtitle = spec.subtitle
            if spec.destructive && !wantsNow && best >= 0.75 {
                action = .confirmRequired(spec.title.lowercased())
                subtitle = "Type '\(spec.phrases[0]) now' to confirm"
            } else {
                action = spec.action
            }
            out.append(Command(id: "sys:\(spec.phrases[0].replacingOccurrences(of: " ", with: "-"))",
                               title: spec.title, subtitle: subtitle, icon: spec.icon, score: best, action: action))
        }
        return out.sorted { $0.score > $1.score }
    }

    @MainActor
    static func results(for query: String, context: QueryContext = .empty) -> [SearchResult] {
        matches(query).map { cmd in
            SearchResult(id: cmd.id, kind: .systemCommand, title: cmd.title, subtitle: cmd.subtitle,
                         icon: .system(cmd.icon), score: cmd.score, shortcutHint: "⏎ Run") {
                await run(cmd.action, context: context)
            }
        }
    }

    // MARK: - Execution

    private static var caffeinate: Process?

    @MainActor
    static func run(_ action: Action, context: QueryContext) async -> ResultOutcome {
        switch action {
        case .confirmRequired(let what):
            return .error("Type '\(what) now' to confirm")
        case .sleep:
            return shell(["/usr/bin/pmset", "sleepnow"])
        case .lock:
            let cg = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
            if FileManager.default.isExecutableFile(atPath: cg) { return shell([cg, "-suspend"]) }
            return shell(["/usr/bin/pmset", "displaysleepnow"])
        case .restart:
            return appleScript("tell application \"System Events\" to restart")
        case .shutDown:
            return appleScript("tell application \"System Events\" to shut down")
        case .logOut:
            return appleScript("tell application \"System Events\" to log out")
        case .darkMode(let dark):
            let value = dark.map { $0 ? "true" : "false" } ?? "not dark mode"
            return appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
        case .emptyTrash:
            return appleScript("tell application \"Finder\" to empty trash")
        case .mute(let on):
            return appleScript(on ? "set volume with output muted" : "set volume without output muted")
        case .volume(let n):
            return appleScript("set volume output volume \(n)")
        case .volumeStep(let delta):
            let script = "set v to output volume of (get volume settings)\nset volume output volume (v + (\(delta)))"
            return appleScript(script)
        case .wifi(let on):
            let iface = wifiInterface()
            return shell(["/usr/sbin/networksetup", "-setairportpower", iface, on ? "on" : "off"])
        case .bluetooth:
            open("x-apple.systempreferences:com.apple.BluetoothSettings")
            return .dismiss
        case .doNotDisturb:
            open("x-apple.systempreferences:com.apple.Focus-Settings.extension")
            return .dismiss
        case .screenshot:
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let path = NSString(string: "~/Desktop/Screenshot \(df.string(from: Date())).png").expandingTildeInPath
            // Let the panel close before the crosshair appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                _ = shell(["/usr/sbin/screencapture", "-i", path])
            }
            return .dismiss
        case .keepAwake(let on):
            let running = caffeinate?.isRunning == true
            let want = on ?? !running
            if want && !running {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                p.arguments = ["-d", "-i"]
                do { try p.run(); caffeinate = p } catch { return .error("caffeinate failed: \(error.localizedDescription)") }
            } else if !want, running {
                caffeinate?.terminate(); caffeinate = nil
            }
            return .dismiss
        case .eject:
            return appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)")
        case .hideOthers:
            let keep = [context.frontmostAppName, "Finder", "Navi"].compactMap { $0 }
            let clause = keep.map { "name is not \"\($0)\"" }.joined(separator: " and ")
            return appleScript("tell application \"System Events\" to set visible of (every process whose visible is true and \(clause)) to false")
        case .showDesktop:
            return appleScript("tell application \"System Events\" to set visible of (every process whose visible is true and name is not \"Finder\" and name is not \"Navi\") to false")
        case .quitApp(let name, let force):
            let n = name.lowercased()
            let apps = NSWorkspace.shared.runningApplications.filter {
                guard let ln = $0.localizedName?.lowercased() else { return false }
                return ln == n || ln.hasPrefix(n) || ln.contains(n)
            }
            guard !apps.isEmpty else { return .error("No running app named “\(name)”") }
            for a in apps { if force { a.forceTerminate() } else { a.terminate() } }
            return .dismiss
        }
    }

    // MARK: Helpers

    private static func open(_ urlString: String) {
        if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
    }

    /// Runs a shell tool synchronously (these all return in well under 100 ms).
    @discardableResult
    static func shell(_ argv: [String]) -> ResultOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.router.error("\(argv.joined(separator: " ")) exited \(p.terminationStatus): \(msg)")
                return .error(msg.isEmpty ? "\(argv[0]) failed (\(p.terminationStatus))" : msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .dismiss
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func appleScript(_ source: String) -> ResultOutcome {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .error("Bad AppleScript") }
        script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
            Log.router.error("AppleScript failed (\(code)): \(msg)")
            if code == -1743 || code == -1744 || msg.contains("not allowed") {
                return .error("Navi needs Automation permission — grant it in System Settings → Privacy & Security → Automation")
            }
            return .error(msg)
        }
        return .dismiss
    }

    /// Finds the Wi-Fi hardware port (usually en0, en1 on some desktops).
    static func wifiInterface() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallhardwareports"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "en0" }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var sawWifi = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { sawWifi = line.contains("Wi-Fi") || line.contains("AirPort") }
            else if sawWifi, line.hasPrefix("Device:") {
                return line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }
}
