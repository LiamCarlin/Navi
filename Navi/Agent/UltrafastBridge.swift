import AppKit
import Foundation

/// Browser tasks run on **jev-ultrafast** (Browser Use × TypeSafe,
/// https://github.com/browser-use/jev-ultrafast, vendored under
/// `vendor/jev-ultrafast`): Jev picks the operation + target from an indexed
/// DOM element table in one request per step; a small LLM writes text only
/// for TYPE_TEXT. Chrome is driven over CDP through Browser Harness.
///
/// Navi launches `scripts/ultrafast/navi_runner.py` under `uv` and turns its
/// JSON-lines output into `AgentEvent`s. Keys travel in the environment.
enum UltrafastBridge {
    // MARK: Runtime location

    /// Repo root that holds `vendor/jev-ultrafast` and `scripts/ultrafast`.
    /// Order: explicit setting → bundled copy → the source checkout.
    static var repoRoot: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let p = UserDefaults.standard.string(forKey: "ultrafastRepoRoot"), !p.isEmpty {
            candidates.append(URL(fileURLWithPath: p))
        }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("ultrafast")) }
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Navi"))
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        candidates.append(appSupport.appendingPathComponent("Navi/ultrafast"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("vendor/jev-ultrafast/pyproject.toml").path) }
    }

    static var vendorDir: URL? { repoRoot?.appendingPathComponent("vendor/jev-ultrafast") }
    static var runnerScript: URL? { repoRoot?.appendingPathComponent("scripts/ultrafast/navi_runner.py") }
    static var uvPath: String? {
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum RuntimeStatus: Equatable {
        case ready(String)          // python version
        case missingUV
        case missingRepo
        case missingVenv
        case error(String)

        var label: String {
            switch self {
            case .ready(let v): return "Installed · \(v)"
            case .missingUV: return "uv not installed (brew install uv)"
            case .missingRepo: return "vendor/jev-ultrafast not found"
            case .missingVenv: return "Runtime not installed — run Install"
            case .error(let e): return e
            }
        }
        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    static func runtimeStatus() -> RuntimeStatus {
        guard uvPath != nil else { return .missingUV }
        guard let vendor = vendorDir else { return .missingRepo }
        let py = vendor.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: py) else { return .missingVenv }
        let (out, code) = shell(py, ["-c", "import sys, jev_ultrafast, browser_harness; print(sys.version.split()[0])"], cwd: vendor)
        return code == 0 ? .ready("Python " + out.trimmingCharacters(in: .whitespacesAndNewlines)) : .missingVenv
    }

    /// `scripts/ultrafast/setup.sh` — installs uv deps into vendor/.venv.
    static func installRuntime() async -> (ok: Bool, log: String) {
        guard let root = repoRoot else { return (false, "vendor/jev-ultrafast not found") }
        return await Task.detached {
            let (out, code) = shell("/bin/zsh", [root.appendingPathComponent("scripts/ultrafast/setup.sh").path], cwd: root, timeout: 600)
            return (code == 0, out)
        }.value
    }

    enum ChromeStatus: Equatable {
        case ready, chromeNotRunning, debuggingBlocked, runtimeMissing, error(String)
        var label: String {
            switch self {
            case .ready: return "Chrome connected"
            case .chromeNotRunning: return "Chrome is not running"
            case .debuggingBlocked: return "Enable remote debugging in Chrome (chrome://inspect/#remote-debugging)"
            case .runtimeMissing: return "Runtime not installed"
            case .error(let e): return e
            }
        }
    }

    static func chromeStatus() async -> ChromeStatus {
        guard let root = repoRoot else { return .runtimeMissing }
        return await Task.detached {
            let (out, _) = shell("/bin/zsh", [root.appendingPathComponent("scripts/ultrafast/doctor.sh").path], cwd: root, timeout: 40)
            let line = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            switch line {
            case "ready": return .ready
            case "chrome-not-running": return .chromeNotRunning
            case "debugging-blocked": return .debuggingBlocked
            case "runtime-missing": return .runtimeMissing
            default: return .error(line.isEmpty ? "Unknown doctor output" : line)
            }
        }.value
    }

    static func openChromeDebuggingPage() {
        let url = URL(string: "chrome://inspect/#remote-debugging")!
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func approveChromeConnection() async -> String {
        guard let root = repoRoot else { return "runtime missing" }
        return await Task.detached {
            shell("/bin/zsh", [root.appendingPathComponent("scripts/ultrafast/approve.sh").path], cwd: root, timeout: 45).0
        }.value
    }

    // MARK: Warm-up

    /// Starts the Browser Harness daemon (Chrome CDP bridge) in the background so
    /// the first browser task skips the ~1 s connect. Safe to call repeatedly.
    static func prewarm() {
        guard let vendor = vendorDir else { return }
        let python = vendor.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        Task.detached(priority: .utility) {
            let (out, code) = shell(python, ["-c", "from browser_harness.admin import ensure_daemon; ensure_daemon(); print('warm')"], cwd: vendor, timeout: 30)
            Log.agent.info("ultrafast prewarm: \(code == 0 ? "ready" : out.suffix(160))")
        }
    }

    // MARK: Run

    /// Environment for the runner: Jev transport + keys, text-helper key.
    static func environment() -> [String: String]? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        env["TYPESAFE_MODEL"] = UserDefaults.standard.string(forKey: "jevModel") ?? "jev-latest"
        let pref = JevProvider(rawValue: UserDefaults.standard.string(forKey: "jevProvider") ?? "") ?? .auto
        switch JevClient.resolveTransport(preference: pref) {
        case .typesafe:
            env["TYPESAFE_API_KEY"] = Keychain.get(.typesafe)
            env.removeValue(forKey: "NAVI_JEV_TRANSPORT")
        case .vercelGateway:
            env["AI_GATEWAY_API_KEY"] = Keychain.get(.vercelGateway)
            env["NAVI_JEV_TRANSPORT"] = "vercel"
        case nil:
            return nil
        }
        if let k = Keychain.get(.anthropic) { env["ANTHROPIC_API_KEY"] = k }
        // Text helper for TYPE_TEXT: Claude Haiku on the Anthropic key. Developers can
        // instead export TEXT_MODEL_API_KEY / TEXT_MODEL_BASE_URL / TEXT_MODEL (upstream's
        // OpenAI-compatible helper) before launching Navi; those pass through untouched.
        env["NAVI_TEXT_MODEL"] = UserDefaults.standard.string(forKey: "ultrafastTextModel") ?? "claude-haiku-4-5"
        // Coach (Claude diagnoses a failing run once): the agent model from Settings.
        env["NAVI_AGENT_MODEL"] = UserDefaults.standard.string(forKey: "agentModel") ?? "claude-sonnet-5"
        // Web-app playbooks (`AppSkills`): the runner adds the one matching each page to Jev's state.
        env["NAVI_PLAYBOOKS_JSON"] = AppSkills.webPlaybooksJSON()
        return env
    }

    /// What happens to the runner's tab when the run ends (`NAVI_TAB_POLICY`).
    /// The tab is the deliverable of an effect task ("make a Google Doc"), so it
    /// stays open; in background mode it is also brought forward on completion
    /// when Settings allow. A background *lookup* closes its tab on completion —
    /// its answer is in the panel and the user never saw the tab. Failures always
    /// keep the tab so the user can take over where the run stopped.
    static func tabPolicy(task: String, background: Bool, revealWhenDone: Bool) -> String {
        guard background else { return "keep" }
        if AgentRun.isLookup(task) { return "close" }
        return revealWhenDone ? "reveal" : "keep"
    }

    /// Runs one browser task, streaming events into `handle`. Returns when the
    /// runner exits, with the final page's visible text when the task
    /// completed (nil otherwise). Cancellation kills the subprocess.
    ///
    /// `background`: leave Chrome where it is and work in a tab that is not
    /// brought to the front (`NAVI_BACKGROUND_TAB`), so the user keeps their
    /// current window while the task runs. CDP input and DOM reads don't need
    /// the tab to be visible.
    ///
    /// `attachToCurrentTab`: `startURL` is the tab that is open now — the runner
    /// works on that tab (a follow-up like "look up X" on the site just opened)
    /// instead of opening a second one.
    static func run(task: String, startURL: String?, handle: AgentRunHandle, maxSteps: Int, screenshots: Bool,
                    background: Bool = false, attachToCurrentTab: Bool = false) async -> String? {
        let search = searchURL(for: task)
        let first = startURL ?? search
        let attachURL = attachToCurrentTab && startURL != nil ? startURL : nil
        if background {
            handle.emit(.status("Working in a background Chrome tab — keep using your Mac"))
        } else {
            await bringBrowserForward()
        }
        // "Go to YouTube and open it": the page itself is the deliverable. Jev finding
        // nothing to do on it means the task is done — not a reason to close the tab
        // the user just watched open and start over from a Google search.
        let navigationOnly = first != search && isNavigationOnly(task)
        var (outcome, text) = await runOnce(task: task, url: first, handle: handle, maxSteps: maxSteps, screenshots: screenshots,
                                            allowEarlyBlockRetry: first != search, background: background,
                                            openedIsDone: navigationOnly, attachURL: attachURL)
        if outcome == .blockedBeforeActing {
            // Jev found nothing useful on the starting page (e.g. an unrelated tab).
            // Start over from a search-results page for the task.
            handle.emit(.status("Nothing actionable on \(first) — retrying from a Google search"))
            (outcome, text) = await runOnce(task: task, url: search, handle: handle, maxSteps: maxSteps, screenshots: screenshots,
                                            allowEarlyBlockRetry: false, background: background)
        }
        // The runner fronted its tab inside Chrome ("reveal"); Chrome itself may still
        // be behind the user's windows — the tab *is* the result, so bring it forward.
        if outcome == .completed, background, lastTabPolicy == "reveal" { await bringBrowserForward() }
        return text
    }

    /// The policy of the most recent run (set in `runOnce`), for `run`'s reveal.
    nonisolated(unsafe) private static var lastTabPolicy = "keep"

    /// The runner works in its own Chrome tab; make Chrome frontmost so the
    /// user watches the task happen instead of wondering what the new tab is.
    @MainActor
    static func bringBrowserForward() {
        let chrome = ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac"]
        for bid in chrome {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate()
                return
            }
        }
    }

    enum RunOutcome: Equatable { case completed, failed, cancelled, blockedBeforeActing }

    /// Is the task satisfied by opening its page — nothing to do once there?
    /// "go to youtube", "open the youtube website and open it", "pull up
    /// reddit in chrome", "navigate to github.com please".
    static func isNavigationOnly(_ task: String) -> Bool {
        var t = task.lowercased()
        // A destination must be named: a URL or a site Navi knows ("the settings page" is not one).
        var named = false
        if let u = TextCandidates.urls(in: task).first { t = t.replacingOccurrences(of: u.lowercased(), with: " "); named = true }
        if let site = knownSiteName(in: task) { t = t.replacingOccurrences(of: site, with: " "); named = true }
        guard named else { return false }
        t = " " + t.replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression) + " "
        let fillers = ["please", "can you", "could you", "for me", "and open it", "open it", "and go there", "the website", "the web page",
                       "the webpage", "the site", "the page", "website", "webpage", "site", "page", "in chrome", "in the browser",
                       "in safari", "on chrome", "on the web", "online", "the", "a", "to", "and", "then", "on", "up"]
        let verbs = ["go to", "goto", "navigate to", "open", "visit", "browse to", "browse", "pull up", "bring up", "show me", "show",
                     "load", "launch", "take me to", "get me to", "head to"]
        for f in fillers where f.contains(" ") { t = t.replacingOccurrences(of: " \(f) ", with: " ") }
        var stripped = false
        for v in verbs where t.contains(" \(v) ") { t = t.replacingOccurrences(of: " \(v) ", with: " "); stripped = true }
        guard stripped else { return false }
        var words = t.split(whereSeparator: { $0 == " " }).map(String.init)
        words.removeAll { fillers.contains($0) }
        return words.isEmpty
    }

    /// The well-known site the task names (the key of `knownSiteURL`), if any.
    static func knownSiteName(in task: String) -> String? {
        let lower = task.lowercased()
        return knownSites.first { lower.contains($0.0) }?.0.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func runOnce(task: String, url: String, handle: AgentRunHandle, maxSteps: Int, screenshots: Bool,
                        allowEarlyBlockRetry: Bool, background: Bool = false, openedIsDone: Bool = false,
                        attachURL: String? = nil) async -> (outcome: RunOutcome, text: String?) {
        guard let vendor = vendorDir, let runner = runnerScript,
              case let python = vendor.appendingPathComponent(".venv/bin/python").path,
              FileManager.default.isExecutableFile(atPath: python) else {
            handle.emit(.failed("Browser runtime not installed. Navi → Settings → Agent → Install jev-ultrafast."))
            return (.failed, nil)
        }
        guard var env = environment() else {
            handle.emit(.failed(NaviError.missingAPIKey(.typesafe).localizedDescription))
            return (.failed, nil)
        }
        if background { env["NAVI_BACKGROUND_TAB"] = "1" }
        if let attachURL { env["NAVI_ATTACH_URL"] = attachURL }
        let reveal = UserDefaults.standard.object(forKey: "agentRevealWhenDone") as? Bool ?? true
        let policy = tabPolicy(task: task, background: background, revealWhenDone: reveal)
        env["NAVI_TAB_POLICY"] = policy
        lastTabPolicy = policy
        var outcome: RunOutcome = .failed
        var finalText: String?
        let proc = Process()
        // The venv's interpreter directly: no uv resolution, no lockfile check per task.
        proc.executableURL = URL(fileURLWithPath: python)
        var args = ["-u", runner.path, "--url", url, "--goal", task]
        if maxSteps > 0 { args += ["--max-steps", String(maxSteps)] }
        if screenshots { args.append("--screenshots") }
        proc.arguments = args
        proc.currentDirectoryURL = vendor
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        handle.emit(.planned("Jev Ultrafast · Browser Use × TypeSafe · \(url)" + (attachURL != nil ? " (current tab)" : "")))
        do { try proc.run() } catch {
            handle.emit(.failed("Could not start runner: \(error.localizedDescription)"))
            return (.failed, nil)
        }
        Log.agent.info("ultrafast runner started pid=\(proc.processIdentifier)")

        let stderrTask = Task.detached { () -> String in
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        var finished = false
        var stepIndex = 0
        var lastDecision = ""
        // Keep the raw event stream of the last run for debugging (local only).
        let logDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Navi")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("ultrafast-last-run.jsonl")
        // A dictionary, not a bare string: NSJSONSerialization raises an ObjC exception
        // (uncatchable by `try?`) for a top-level string without `.fragmentsAllowed`.
        let startLine = (try? JSONSerialization.data(withJSONObject: ["event": "start", "url": url, "task": task])) ?? Data("{\"event\":\"start\"}".utf8)
        FileManager.default.createFile(atPath: logURL.path, contents: startLine + Data("\n".utf8))
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        defer { try? logHandle?.close() }
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                logHandle?.write(Data((line + "\n").utf8))
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = json["event"] as? String else { continue }
                switch event {
                case "status":
                    handle.emit(.status(json["message"] as? String ?? ""))
                case "guidance":
                    handle.emit(.planned("Guidance for Jev:\n\(json["text"] as? String ?? "")"))
                case "ready":
                    let n = json["elements"] as? Int ?? 0
                    handle.emit(.status("Page ready · \(n) elements · \(json["title"] as? String ?? "")"))
                case "decision":
                    let op = json["operation"] as? String ?? "?"
                    let conf = Int(((json["confidence"] as? Double) ?? 0) * 100)
                    let ms = json["latency_ms"] as? Int ?? 0
                    lastDecision = "Jev · \(op)\((json["target"] as? String).map { " [\($0)]" } ?? "") \(conf)% · \(ms) ms"
                    handle.emit(.status(lastDecision))
                case "step":
                    stepIndex += 1
                    let kind = (json["kind"] as? String ?? "").uppercased()
                    let action = (json["action"] as? String ?? "").split(separator: "→").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                    var desc: String
                    switch kind {
                    case "FILL": desc = "Type “\((json["text"] as? String) ?? "")” into \(action)"
                    case "CLICK": desc = "Click \(action)"
                    case "SELECT": desc = "Select \(action)"
                    case "SCROLL": desc = "Scroll"
                    case "WAIT": desc = "Wait for the page"
                    default: desc = "\(kind.capitalized) \(action)"
                    }
                    if let note = json["note"] as? String, !note.isEmpty {
                        desc += " (\(note))"      // e.g. "could not be clicked (covered or off-screen); no longer offered"
                    } else if let changed = json["page_changed"] as? Bool, !changed, kind != "WAIT" {
                        desc += " (no change)"
                    }
                    handle.emit(.step(index: stepIndex, description: desc))
                case "screenshot":
                    if let b64 = json["jpeg_base64"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
                        handle.emit(.screenshot(img))
                    }
                case "done":
                    finished = true
                    let status = json["status"] as? String ?? "done"
                    let summary = json["summary"] as? String ?? ""
                    let ms = json["elapsed_ms"] as? Int ?? 0
                    let opened = "Opened \(URL(string: json["url"] as? String ?? url)?.host ?? url)"
                    switch status {
                    case "done":
                        outcome = .completed
                        finalText = [json["title"] as? String ?? "", json["url"] as? String ?? "", json["page_text"] as? String ?? ""]
                            .joined(separator: "\n")
                        handle.emit(.completed(summary: openedIsDone && stepIndex == 0 ? opened : "\(summary) (\(stepIndex) steps · \(Double(ms) / 1000)s)"))
                    case "cancelled":
                        outcome = .cancelled
                        handle.emit(.cancelled)
                    default:
                        if stepIndex == 0, openedIsDone {
                            // The page is open; that was the task.
                            outcome = .completed
                            finalText = [json["title"] as? String ?? "", json["url"] as? String ?? "", json["page_text"] as? String ?? ""]
                                .joined(separator: "\n")
                            handle.emit(.completed(summary: opened))
                        } else if stepIndex == 0, allowEarlyBlockRetry {
                            outcome = .blockedBeforeActing
                        } else {
                            outcome = .failed
                            handle.emit(.failed("Blocked: \(summary)"))
                        }
                    }
                case "error":
                    finished = true
                    outcome = .failed
                    handle.emit(.failed(json["message"] as? String ?? "Runner error"))
                default: break
                }
            }
        } catch {
            Log.agent.error("ultrafast stdout read failed: \(error.localizedDescription)")
        }
        if Task.isCancelled, proc.isRunning {
            proc.interrupt()
            try? await Task.sleep(for: .milliseconds(400))
            if proc.isRunning { proc.terminate() }
            if !finished { handle.emit(.cancelled); finished = true; outcome = .cancelled }
        }
        proc.waitUntilExit()
        let stderr = await stderrTask.value
        if !finished {
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: " · ")
            handle.emit(.failed("Runner exited (\(proc.terminationStatus)). \(tail)"))
            outcome = .failed
        } else if !stderr.isEmpty {
            Log.agent.debug("ultrafast stderr: \(stderr.suffix(600))")
        }
        return (outcome, outcome == .completed ? finalText : nil)
    }

    // MARK: Helpers

    /// A Google search for the task, with launcher chatter stripped
    /// ("open chrome, search for X and click the first result" → "X").
    static func searchURL(for task: String) -> String {
        "https://www.google.com/search?hl=en&q=" + (searchQuery(for: task)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? "")
    }

    /// The part of the task worth typing into a search engine.
    static func searchQuery(for task: String) -> String {
        var q = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading launcher clauses: "open chrome,", "go to the browser and", "in safari", "online", …
        let leading = [
            #"^(please\s+)?(open|launch|go to|use|switch to)\s+(the\s+)?(browser|chrome|google chrome|safari|a browser|the web|the internet)\s*(,|and|then|to|;)?\s*"#,
            #"^(in|on|using|with)\s+(the\s+)?(browser|chrome|google chrome|safari|the web|the internet)\s*(,|and|then)?\s*"#,
            #"^(online|on the web|on the internet)\s*,?\s*"#,
            #"^(search|google|look up|look for|find me|find|search for|search the web for|search google for)\s+(for\s+)?"#,
            #"^(please\s+)?"#,
        ]
        var changed = true
        while changed {
            changed = false
            for pat in leading {
                if let r = q.range(of: pat, options: [.regularExpression, .caseInsensitive]), !r.isEmpty {
                    q.removeSubrange(r); q = q.trimmingCharacters(in: .whitespaces); changed = true
                }
            }
        }
        // Trailing "and click/open the first result", "then …" — instructions for the agent, not the search.
        let trailing = [
            #"\s*(,|and|then|;)?\s*(click|open|tap|choose|select)\s+(on\s+)?(the\s+)?(first|top|best|1st)\s+(result|link|one|option|listing)\b.*$"#,
            #"\s*(,|and|then|;)\s*(click|open|tap|choose|select|book|buy|add)\b.*$"#,
        ]
        for pat in trailing {
            if let r = q.range(of: pat, options: [.regularExpression, .caseInsensitive]) { q.removeSubrange(r) }
        }
        q = q.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return q.isEmpty ? task : q
    }

    /// A well-known site named in the task, if any.
    static func knownSiteURL(in task: String) -> String? {
        let lower = task.lowercased()
        return knownSites.first { lower.contains($0.0) }?.1
    }

    static let knownSites: [(String, String)] = [
        ("google flights", "https://www.google.com/travel/flights?hl=en"), ("flights", "https://www.google.com/travel/flights?hl=en"),
        ("youtube", "https://www.youtube.com"), ("amazon", "https://www.amazon.com"), ("wikipedia", "https://en.wikipedia.org/wiki/Main_Page"),
        ("github", "https://github.com"), ("gmail", "https://mail.google.com"), ("google maps", "https://www.google.com/maps"),
        ("twitter", "https://x.com"), (" x.com", "https://x.com"), ("linkedin", "https://www.linkedin.com"), ("reddit", "https://www.reddit.com"),
        ("hacker news", "https://news.ycombinator.com"), ("airbnb", "https://www.airbnb.com"), ("booking.com", "https://www.booking.com"),
        ("google docs", "https://docs.google.com"), ("notion", "https://www.notion.so"), ("chatgpt", "https://chatgpt.com"),
        ("ticketmaster", "https://www.ticketmaster.com"), ("stubhub", "https://www.stubhub.com"), ("seatgeek", "https://seatgeek.com"),
        ("eventbrite", "https://www.eventbrite.com"), ("expedia", "https://www.expedia.com"), ("kayak", "https://www.kayak.com"),
        ("yelp", "https://www.yelp.com"), ("doordash", "https://www.doordash.com"), ("uber eats", "https://www.ubereats.com"),
        ("netflix", "https://www.netflix.com"), ("spotify", "https://open.spotify.com"), ("ebay", "https://www.ebay.com"),
        ("craigslist", "https://www.craigslist.org"), ("zillow", "https://www.zillow.com"), ("instagram", "https://www.instagram.com"),
    ]

    /// Picks a start URL for a browser task: explicit URL in the task, a known
    /// site name, or the current browser tab when a browser is frontmost.
    static func startURL(for task: String, context: QueryContext) -> String? {
        if let m = task.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression) {
            return String(task[m])
        }
        if let site = knownSiteURL(in: task) { return site }
        let lower = task.lowercased()
        let sites: [(String, String)] = [
            ("google flights", "https://www.google.com/travel/flights?hl=en"), ("flights", "https://www.google.com/travel/flights?hl=en"),
            ("youtube", "https://www.youtube.com"), ("amazon", "https://www.amazon.com"), ("wikipedia", "https://en.wikipedia.org/wiki/Main_Page"),
            ("github", "https://github.com"), ("gmail", "https://mail.google.com"), ("google maps", "https://www.google.com/maps"),
            ("twitter", "https://x.com"), (" x.com", "https://x.com"), ("linkedin", "https://www.linkedin.com"), ("reddit", "https://www.reddit.com"),
            ("hacker news", "https://news.ycombinator.com"), ("airbnb", "https://www.airbnb.com"), ("booking.com", "https://www.booking.com"),
            ("google docs", "https://docs.google.com"), ("notion", "https://www.notion.so"), ("chatgpt", "https://chatgpt.com"),
        ]
        for (name, url) in sites where lower.contains(name) { return url }
        if let m = task.range(of: #"\b([a-z0-9-]+\.)+(com|org|net|io|ai|dev|app|co|edu|gov|so|sh)\b(/[^\s]*)?"#, options: [.regularExpression, .caseInsensitive]) {
            return "https://" + String(task[m])
        }
        let browsers = ["com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"]
        if let bid = context.frontmostApp, browsers.contains(bid), let url = FrontmostProbe.browserURL(bundleID: bid), url.hasPrefix("http") {
            return url
        }
        return nil
    }

    @discardableResult
    static func shell(_ launchPath: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 20) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (error.localizedDescription, -1) }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
