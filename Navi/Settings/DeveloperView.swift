import SwiftUI
import AppKit

// Everything in this file is developer-facing: it is the one place in the app
// that may name the engines behind Navi (Jev / TypeSafe, Claude / Anthropic,
// Gemini), model IDs, token prices, latencies and transports.

/// Settings → Developer. Hidden unless `DeveloperMode.isEnabled` (⌥-click
/// the version on the About page, or `defaults write com.liamcarlin.navi
/// developerMode -bool YES`).
///
/// Sidebar wiring: `SettingsSection.providers` (listed only in developer
/// mode) is rendered by `SettingsRootView` through `ProvidersView`, which
/// shows this view. The account workstream can instead wire
/// `DeveloperView.developerSection` straight into its sidebar.
struct DeveloperView: View {
    /// Title, symbol and view for a sidebar entry — for the account workstream's `SettingsRootView`.
    @MainActor static var developerSection: (title: String, symbol: String, view: AnyView) {
        ("Developer", "hammer", AnyView(DeveloperView()))
    }

    var body: some View {
        FormPage(title: "Developer", subtitle: "Bring your own keys — for development. Nothing here is needed to use Navi.") {
            KeychainStateBanner()
            ProviderKeySections()
            ModelSection()
            AgentTuningSection()
            BrowserRuntimeSection()
            TokenUsageSection()
            DiagnosticsSection()
        }
    }
}

// MARK: - Provider keys

/// API keys, stored in the macOS Keychain. Never leave this Mac except to call the provider.
struct ProviderKeySections: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        Section {
            APIKeyRow(key: .typesafe, title: "Jev (TypeSafe)", subtitle: "System One — intent routing, agent safety gating, memory triage. Direct API.",
                      placeholder: "ts-…", optional: settings.jevProvider == .vercelGateway, test: ProviderTests.jev)
            APIKeyRow(key: .vercelGateway, title: "Jev via Vercel AI Gateway", subtitle: "Same model (typesafe-ai/jev) billed through Vercel. Use this if you don't have TypeSafe early access.",
                      placeholder: "vck_…", optional: settings.jevProvider != .vercelGateway, test: ProviderTests.jevVercel)
            Picker("Jev transport", selection: $settings.jevProvider) {
                ForEach(JevProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            JevTransportStatus()
            APIKeyRow(key: .anthropic, title: "Anthropic (Claude)", subtitle: "System Two — answers, computer-use agent, fallback digest.",
                      placeholder: "sk-ant-…", test: ProviderTests.claude)
        } header: {
            Text("Keys · required")
        } footer: {
            Text("Keys are stored in the macOS Keychain. One Jev key is enough — TypeSafe direct or Vercel AI Gateway. Auto prefers TypeSafe when both exist.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            APIKeyRow(key: .gemini, title: "Google Gemini", subtitle: "Cheapest vision digest for Screen Memory.",
                      placeholder: "AIza…", optional: true, test: ProviderTests.gemini)
            APIKeyRow(key: .openai, title: "OpenAI", subtitle: "Reserved for embeddings / alternate models.",
                      placeholder: "sk-…", optional: true, test: ProviderTests.openAI)
            APIKeyRow(key: .deepgram, title: "Deepgram", subtitle: "Voice input (streaming speech-to-text).",
                      placeholder: "…", optional: true, test: ProviderTests.deepgram)
            APIKeyRow(key: .firecrawl, title: "Firecrawl", subtitle: "Clean page text for web answers.",
                      placeholder: "fc-…", optional: true, test: ProviderTests.firecrawl)
        } header: {
            Text("Keys · optional")
        }

        Section("Where to get keys & credits") {
            DealsCard()
        }
    }
}

// MARK: - Models

struct ModelSection: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        Section("Models") {
            ExplainedRow(title: "Jev model", explanation: "TypeSafe id (jev-latest). Via Vercel this maps to typesafe-ai/jev unless you enter a namespaced id.") {
                TextField("jev-latest", text: $settings.jevModel)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Picker("Answers", selection: $settings.answerModel) {
                ForEach(NaviSettings.claudeModels, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Computer-use agent (Claude fallback)", selection: $settings.agentModel) {
                ForEach(NaviSettings.claudeModels, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Screen Memory digest", selection: $settings.digestProvider) {
                ForEach(DigestProvider.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Routing confidence threshold") {
                HStack {
                    Slider(value: $settings.jevConfidenceThreshold, in: 0.3...0.95, step: 0.05).frame(width: 160)
                    Text(String(format: "%.2f", settings.jevConfidenceThreshold)).monospacedDigit().frame(width: 36)
                }
            }
            Text("Below this, the panel shows both the quick match and “Ask Navi” instead of committing to Jev's intent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Agent tuning

/// Driver choice, Jev confidence threshold, Claude fallback budget and the
/// gates — moved here from Settings → Agent.
struct AgentTuningSection: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        Section {
            Picker("Driver", selection: $settings.agentDriver) {
                ForEach(AgentDriver.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(settings.agentDriver.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.agentDriver == .jevFirst {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $settings.agentJevConfidenceThreshold, in: 0.2...0.95, step: 0.05) {
                        Text("Jev confidence threshold")
                    } minimumValueLabel: { Text("20%") } maximumValueLabel: { Text("95%") }
                    Text("Currently \(Int((settings.agentJevConfidenceThreshold * 100).rounded()))% — below this, the step goes to Claude's vision loop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: $settings.agentMaxClaudeFallbacks, in: 0...30) {
                    LabeledContent("Maximum Claude fallbacks per task") {
                        Text("\(settings.agentMaxClaudeFallbacks)").monospacedDigit()
                    }
                }
                Text(driverExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Agent · driver")
        } footer: {
            Text(settings.agentDriver == .jevFirst
                 ? "Each step: enumerate on-screen controls via Accessibility → one Jev call chooses the operation and target (~100 ms) → execute. Field text comes from Claude Haiku; only NEED_VISION, low confidence or a stuck screen wakes the screenshot loop."
                 : "Every step sends a screenshot to Claude. Slower and costlier, but works on canvas apps and anything Accessibility can't describe.")
        }

        Section {
            VStack(alignment: .leading, spacing: 10) {
                gate("Irreversible", "send, pay, delete, post",
                     "After every step Jev answers `is_irreversible` from the step log. With \"Ask before risky actions\" this is the only time the user is interrupted.")
                gate("Prohibited", "credentials, payments, security settings",
                     "Always refused, in every approval mode. Navi hands the task back to the user instead.")
                gate("Stuck", "same screen, no progress",
                     "`is_stuck` and `task_complete` stop the loop early so a confused run doesn't burn steps.")
            }
            .padding(.vertical, 2)
        } header: {
            Text("Agent · what Jev gates")
        } footer: {
            Text("Each gate is one System One call (~100 ms) on the textual step log — no extra screenshots, no extra Claude tokens.")
        }
    }

    private var driverExplanation: String {
        let t = Int((settings.agentJevConfidenceThreshold * 100).rounded())
        let n = settings.agentMaxClaudeFallbacks
        var s = "Jev picks CLICK / TYPE_TEXT / SELECT / KEY / SCROLL / OPEN_APP / OPEN_URL / WAIT / DONE from the accessibility tree. "
        s += t >= 70 ? "A \(t)% bar is strict: expect Claude to step in often on busy screens. "
            : t <= 35 ? "A \(t)% bar is permissive: Jev will act on close calls; keep an approval mode on. "
            : "At \(t)% Jev acts when it clearly prefers one operation and defers ambiguous screens. "
        s += n == 0 ? "With 0 fallbacks the run fails as soon as Jev can't decide." : "Up to \(n) bounded Claude turns (≤3 actions each) per task."
        if !settings.hasJevKey { s += " No Jev key yet — the Claude-only driver will be used until one is added above." }
        return s
    }

    private func gate(_ title: String, _ examples: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(examples).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Browser runtime

/// Status and one-click setup for the jev-ultrafast runtime
/// (Browser Use × TypeSafe) that drives Chrome.
struct BrowserRuntimeSection: View {
    @State private var runtime: UltrafastBridge.RuntimeStatus? = nil
    @State private var chrome: UltrafastBridge.ChromeStatus? = nil
    @State private var busy = false
    @State private var log = ""
    @AppStorage("ultrafastScreenshots") private var screenshots = false
    @AppStorage("ultrafastTextModel") private var textModel = "claude-haiku-4-5"

    var body: some View {
        Section {
            ExplainedRow(title: "Runtime", explanation: "Python 3.12 + browser-harness, installed by uv into vendor/jev-ultrafast/.venv.") {
                HStack(spacing: 8) {
                    StatusDot(level: runtime?.isReady == true ? .ok : (runtime == nil ? .off : .warn))
                    Text(runtime?.label ?? "Checking…").font(.callout)
                    if runtime?.isReady != true {
                        Button(busy ? "Installing…" : "Install") { Task { await install() } }.disabled(busy)
                    }
                }
            }
            ExplainedRow(title: "Chrome", explanation: "One-time: tick “Allow remote debugging for this browser instance” in chrome://inspect. Navi then drives a background tab in your signed-in Chrome.") {
                HStack(spacing: 8) {
                    StatusDot(level: chrome == .ready ? .ok : (chrome == nil ? .off : .warn))
                    Text(chrome?.label ?? "Not checked").font(.callout)
                    Button("Check") { Task { await checkChrome() } }.disabled(busy)
                    if chrome == .debuggingBlocked {
                        Button("Open chrome://inspect") { UltrafastBridge.openChromeDebuggingPage() }
                        Button("Approve connection") { Task { busy = true; log = await UltrafastBridge.approveChromeConnection(); busy = false; await checkChrome() } }
                    }
                }
            }
            Picker("Text helper (TYPE_TEXT only)", selection: $textModel) {
                ForEach(NaviSettings.claudeModels, id: \.id) { Text($0.label).tag($0.id) }
            }
            Toggle("Stream page screenshots to the panel (adds ~50 ms per step; off = upstream default)", isOn: $screenshots)
            if !log.isEmpty {
                ScrollView { Text(log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
        } header: {
            Text("Browser tasks · Jev Ultrafast")
        } footer: {
            Text("Anything Jev classifies as a browser task runs on browser-use/jev-ultrafast: one Jev request per step picks the operation and the exact DOM element (no coordinates, no screenshots in the loop); the text helper only writes what goes into a field. Google Flights search: ~7 s end to end.")
        }
        .task { refresh() }
    }

    private func refresh() {
        Task.detached {
            let r = UltrafastBridge.runtimeStatus()
            await MainActor.run { runtime = r }
        }
    }

    private func install() async {
        busy = true
        let (ok, out) = await UltrafastBridge.installRuntime()
        log = String(out.suffix(1500))
        busy = false
        refresh()
        if ok { await checkChrome() }
    }

    private func checkChrome() async {
        busy = true
        chrome = await UltrafastBridge.chromeStatus()
        busy = false
    }
}

// MARK: - Token usage & prices

/// Local, rough cost tracking. Token counts come from provider responses;
/// prices are list prices per million tokens (Sept 2026).
enum Pricing {
    struct Rate { let input: Double; let output: Double }   // $ per MTok

    static func claude(_ model: String) -> Rate {
        if model.contains("opus") { return Rate(input: 5, output: 25) }
        if model.contains("sonnet") { return Rate(input: 2, output: 10) }
        return Rate(input: 1, output: 5)                     // haiku 4.5
    }
    static let jevInputPerMTok = 0.042
    /// Typical Navi Jev request (structured state + a few questions).
    static let jevTokensPerCall = 1_200.0
}

struct TokenUsageSection: View {
    @EnvironmentObject private var settings: NaviSettings

    private var rate: Pricing.Rate { Pricing.claude(settings.answerModel) }
    private var claudeCost: Double {
        Double(settings.usageClaudeInputTokens) / 1e6 * rate.input + Double(settings.usageClaudeOutputTokens) / 1e6 * rate.output
    }
    private var jevCost: Double {
        Double(settings.usageJevCalls) * Pricing.jevTokensPerCall / 1e6 * Pricing.jevInputPerMTok
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                tile("Jev calls", Fmt.tokens(settings.usageJevCalls), Fmt.usd(jevCost), "bolt.fill")
                tile("Claude in", Fmt.tokens(settings.usageClaudeInputTokens), Fmt.usd(Double(settings.usageClaudeInputTokens) / 1e6 * rate.input), "arrow.down.circle")
                tile("Claude out", Fmt.tokens(settings.usageClaudeOutputTokens), Fmt.usd(Double(settings.usageClaudeOutputTokens) / 1e6 * rate.output), "arrow.up.circle")
                tile("Digested frames", Fmt.tokens(settings.usageDigestFrames), "", "photo.stack")
            }
            .padding(.vertical, 4)
            LabeledContent("Estimated total") {
                Text(Fmt.usd(claudeCost + jevCost)).font(.title3.weight(.semibold)).monospacedDigit()
            }
        } header: {
            Text("Tokens & cost")
        } footer: {
            Text("Counted on this Mac since the last reset (Usage → Reset counters). Dollar figures are estimates from list prices.")
        }

        Section("Prices used") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Text("Input / MTok").font(.caption).foregroundStyle(.secondary)
                    Text("Output / MTok").font(.caption).foregroundStyle(.secondary)
                }
                priceRow("Jev (jev-latest)", "$0.042", "free")
                priceRow("claude-opus-5", "$5", "$25", highlight: settings.answerModel.contains("opus"))
                priceRow("claude-sonnet-5", "$2", "$10", highlight: settings.answerModel.contains("sonnet"))
                priceRow("claude-haiku-4-5", "$1", "$5", highlight: settings.answerModel.contains("haiku"))
            }
            Text("Claude tokens are pooled across models; the estimate applies the Answers model's rate (\(settings.answerModel)). Jev cost assumes ~\(Int(Pricing.jevTokensPerCall)) input tokens per call.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile(_ label: String, _ value: String, _ cost: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(cost.isEmpty ? " " : "≈ \(cost)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func priceRow(_ m: String, _ i: String, _ o: String, highlight: Bool = false) -> some View {
        GridRow {
            Text(m).fontWeight(highlight ? .semibold : .regular)
            Text(i).monospacedDigit()
            Text(o).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Bundle") { Text(Bundle.main.bundleIdentifier ?? "—").textSelection(.enabled) }
            LabeledContent("Data") { Text(NaviSettings.dataDirectory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            LabeledContent("Logs") {
                Text("log stream --predicate 'subsystem == \"com.liamcarlin.navi\"'")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            LinkPill(title: "Jev / TypeSafe docs", url: "https://docs.typesafe.ai")
            LinkPill(title: "TypeSafe console", url: "https://console.typesafe.ai")
            LinkPill(title: "Claude API docs", url: "https://platform.claude.com/docs")
            LinkPill(title: "Navi source", url: "https://github.com/liamcarlin/Navi")
        }

        Section {
            HStack {
                Button("Turn developer mode off") {
                    DeveloperMode.isEnabled = false
                    SettingsNavigator.shared.go(.about)
                }
                Text("⌥-click the version on the About page to turn it back on.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - Key row

struct APIKeyRow: View {
    let key: Keychain.Key
    let title: String
    let subtitle: String
    var placeholder: String = ""
    var optional: Bool = false
    /// Returns a detail string (e.g. "142 ms") on success; throws on failure.
    var test: (() async throws -> String)? = nil

    @State private var value = ""
    @State private var stored = ""
    @State private var testState: TestState = .idle
    @State private var savedFlash = false

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    private var fromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment[key.rawValue] ?? "").isEmpty
    }
    private var dirty: Bool { value != stored }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if optional { Text("optional").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                statusPill
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .disabled(fromEnvironment)
                Button(savedFlash ? "Saved" : "Save", action: save)
                    .disabled(!dirty || fromEnvironment)
                    .controlSize(.regular)
                if !stored.isEmpty && !fromEnvironment {
                    Button { value = ""; save() } label: { Image(systemName: "trash") }
                        .help("Remove key")
                }
                if test != nil {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if testState == .running { ProgressView().controlSize(.small).frame(width: 34) } else { Text("Test") }
                    }
                    .disabled(stored.isEmpty || testState == .running)
                }
            }
            if fromEnvironment {
                Text("Using \(key.rawValue) from the environment (overrides Keychain).")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if case .failed(let msg) = testState {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .naviKeysChanged)) { _ in load() }
    }

    @ViewBuilder private var statusPill: some View {
        switch testState {
        case .ok(let d): StatusPill(text: "OK · \(d)", level: .ok)
        case .failed: StatusPill(text: "Failed", level: .bad)
        case .running: StatusPill(text: "Testing…", level: .warn)
        case .idle:
            if stored.isEmpty { StatusPill(text: optional ? "Not set" : "Missing", level: optional ? .off : .bad) }
            else { StatusPill(text: "Saved", level: .ok) }
        }
    }

    private func load() {
        stored = Keychain.get(key) ?? ""
        value = stored
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(key, value: trimmed.isEmpty ? nil : trimmed)
        NotificationCenter.default.post(name: .naviSettingsChanged, object: nil)
        stored = Keychain.get(key) ?? ""
        value = stored
        testState = .idle
        savedFlash = true
        NotificationCenter.default.post(name: .naviKeysChanged, object: key.rawValue)
        Task { try? await Task.sleep(for: .seconds(1.2)); savedFlash = false }
    }

    private func runTest() async {
        guard let test else { return }
        testState = .running
        do {
            let detail = try await test()
            testState = .ok(detail)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Connection tests

enum ProviderTests {
    private static func timed<T>(_ op: () async throws -> T) async throws -> (T, Int) {
        let t = Date()
        let v = try await op()
        return (v, Int(Date().timeIntervalSince(t) * 1000))
    }

    @MainActor static func jev() async throws -> String {
        let client = AppDelegate.shared?.services.jev ?? JevClient()
        let (r, _) = try await timed {
            try await client.ask(state: "ping",
                                 questions: ["ok": .noul(instructions: "The word 'ping' appears in the state")],
                                 cacheable: false)
        }
        let p = r["ok"]?.noul ?? 0
        return "\(r.latencyMs) ms · P(ok)=\(String(format: "%.2f", p))"
    }

    @MainActor static func jevVercel() async throws -> String {
        let client = AppDelegate.shared?.services.jev ?? JevClient()
        let (r, _) = try await timed {
            try await client.ask(state: "ping",
                                 questions: ["ok": .noul(instructions: "The word 'ping' appears in the state")],
                                 cacheable: false, transport: .vercelGateway)
        }
        let p = r["ok"]?.noul ?? 0
        return "\(r.latencyMs) ms · P(ok)=\(String(format: "%.2f", p)) · via Vercel"
    }

    @MainActor static func claude() async throws -> String {
        let client = AppDelegate.shared?.services.claude ?? ClaudeClient()
        let (text, ms) = try await timed {
            try await client.complete(model: "claude-haiku-4-5", system: nil, prompt: "Reply with OK", maxTokens: 5)
        }
        return "\(ms) ms · \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))"
    }

    static func gemini() async throws -> String {
        guard let key = Keychain.get(.gemini) else { throw NaviError.missingAPIKey(.gemini) }
        var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        comps.queryItems = [URLQueryItem(name: "key", value: key)]
        return try await get(comps.url!, headers: [:]) { json in
            "\((json["models"] as? [Any])?.count ?? 0) models"
        }
    }

    static func openAI() async throws -> String {
        guard let key = Keychain.get(.openai) else { throw NaviError.missingAPIKey(.openai) }
        return try await get(URL(string: "https://api.openai.com/v1/models")!, headers: ["Authorization": "Bearer \(key)"]) { json in
            "\((json["data"] as? [Any])?.count ?? 0) models"
        }
    }

    static func deepgram() async throws -> String {
        guard let key = Keychain.get(.deepgram) else { throw NaviError.missingAPIKey(.deepgram) }
        return try await get(URL(string: "https://api.deepgram.com/v1/projects")!, headers: ["Authorization": "Token \(key)"]) { json in
            "\((json["projects"] as? [Any])?.count ?? 0) projects"
        }
    }

    static func firecrawl() async throws -> String {
        guard let key = Keychain.get(.firecrawl) else { throw NaviError.missingAPIKey(.firecrawl) }
        return try await get(URL(string: "https://api.firecrawl.dev/v1/team/credit-usage")!, headers: ["Authorization": "Bearer \(key)"]) { json in
            if let d = json["data"] as? [String: Any], let rem = d["remaining_credits"] as? NSNumber { return "\(rem) credits left" }
            return "authenticated"
        }
    }

    private static func get(_ url: URL, headers: [String: String], summarize: @escaping ([String: Any]) -> String) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let t = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        guard let http = resp as? HTTPURLResponse else { throw NaviError.other("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw NaviError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return "\(ms) ms · \(summarize(json))"
    }
}

// MARK: - Deals card

struct DealsCard: View {
    struct Deal: Identifiable {
        let id = UUID()
        let name: String
        let url: String
        let note: String
        let use: String
        var redeemed = false
    }

    static let deals: [Deal] = [
        Deal(name: "TypeSafe (Jev)", url: "https://console.typesafe.ai/keys",
             note: "Early access · $0.042 / MTok input, output free", use: "Every routing, gating and triage decision."),
        Deal(name: "Vercel AI Gateway (Jev)", url: "https://vercel.com/ai-gateway/models/jev",
             note: "typesafe-ai/jev · same $0.042 / MTok · no waitlist", use: "Alternative route to Jev; key from Vercel → AI Gateway → API Keys."),
        Deal(name: "Anthropic", url: "https://platform.claude.com",
             note: "YC student deal: $500 credits + Tier 4 limits", use: "Answers and the computer-use agent.", redeemed: true),
        Deal(name: "Google AI Studio", url: "https://aistudio.google.com/apikey",
             note: "YC deal: $2k GCP credits — deals.ycombinator.com/deals/4768", use: "Gemini Flash-Lite screen digests."),
        Deal(name: "OpenAI", url: "https://platform.openai.com/api-keys",
             note: "YC deal: $1k credits", use: "Optional embeddings / alternate models."),
        Deal(name: "Langfuse", url: "https://langfuse.com",
             note: "YC deal: $600 — optional observability", use: "Trace every Jev + Claude call."),
        Deal(name: "Respan", url: "https://respan.ai",
             note: "YC deal: $3k AI gateway — set ANTHROPIC_BASE_URL", use: "Caching, routing and spend caps in front of Claude."),
        Deal(name: "Browser Use", url: "https://browser-use.com",
             note: "YC deal", use: "Cloud browser for long web tasks."),
        Deal(name: "Firecrawl", url: "https://firecrawl.dev",
             note: "YC deal: 10k credits", use: "Clean page text when answering from the web."),
        Deal(name: "Deepgram", url: "https://deepgram.com",
             note: "YC deal: $15k", use: "Voice queries."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.deals) { d in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            LinkPill(title: d.name, url: d.url)
                            if d.redeemed {
                                Text("redeemed").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                            }
                        }
                        Text(d.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(d.use).font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 260, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Image(systemName: "graduationcap").foregroundStyle(.secondary)
                Text("All YC student deals:")
                LinkPill(title: "deals.ycombinator.com/deals?audience=students", url: "https://deals.ycombinator.com/deals?audience=students")
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

/// Shows which Jev transport will actually be used right now.
struct JevTransportStatus: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var tick = 0

    var body: some View {
        let active = JevClient.resolveTransport(preference: settings.jevProvider)
        HStack(spacing: 8) {
            StatusDot(level: active == nil ? .warn : .ok)
            Text(label(active)).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: .naviSettingsChanged)) { _ in tick += 1 }
    }

    private func label(_ t: JevClient.Transport?) -> String {
        switch t {
        case .typesafe: return "Active: TypeSafe API (api.typesafe.ai)"
        case .vercelGateway: return "Active: Vercel AI Gateway (ai-gateway.vercel.sh · typesafe-ai/jev)"
        case .navi: return "Active: Navi Cloud (account)"
        case nil: return "No Jev key yet — Navi routes with local heuristics until one is added."
        }
    }
}

/// Shown while the one-time Keychain read is pending (macOS may be showing an
/// "Allow" prompt behind other windows) or if it failed.
struct KeychainStateBanner: View {
    @State private var state = Keychain.loadState
    var body: some View {
        Group {
            switch state {
            case .loading, .notLoaded:
                Label("Reading keys from the Keychain… If macOS asks whether Navi may access “Navi API keys”, click **Always Allow** — this happens once per Navi update.",
                      systemImage: "key.horizontal").font(.callout)
            case .failed(let code):
                Label("Keychain read failed (\(code)). Keys will work for this session only after you re-enter them.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            case .loaded:
                EmptyView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .naviKeysChanged)) { _ in state = Keychain.loadState }
        .task {
            while state == .loading || state == .notLoaded {
                try? await Task.sleep(for: .milliseconds(500))
                state = Keychain.loadState
            }
        }
    }
}
