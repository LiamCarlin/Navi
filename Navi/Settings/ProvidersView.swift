import SwiftUI
import AppKit

struct ProvidersView: View {
    @EnvironmentObject private var settings: NaviSettings

    static let claudeModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    var body: some View {
        FormPage(title: "AI Providers", subtitle: "Keys are stored in the macOS Keychain and never leave this Mac except to call the provider.") {
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
                Text("Required")
            } footer: {
                Text("One Jev key is enough — TypeSafe direct or Vercel AI Gateway. Auto prefers TypeSafe when both exist.")
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
                Text("Optional")
            }

            Section("Models") {
                ExplainedRow(title: "Jev model", explanation: "TypeSafe id (jev-latest). Via Vercel this maps to typesafe-ai/jev unless you enter a namespaced id.") {
                    TextField("jev-latest", text: $settings.jevModel)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                Picker("Answers", selection: $settings.answerModel) {
                    ForEach(Self.claudeModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Computer-use agent", selection: $settings.agentModel) {
                    ForEach(Self.claudeModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Screen Memory digest", selection: $settings.digestProvider) {
                    ForEach(DigestProvider.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Jev confidence threshold") {
                    HStack {
                        Slider(value: $settings.jevConfidenceThreshold, in: 0.3...0.95, step: 0.05).frame(width: 160)
                        Text(String(format: "%.2f", settings.jevConfidenceThreshold)).monospacedDigit().frame(width: 36)
                    }
                }
            }

            Section("Where to get keys & credits") {
                DealsCard()
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

extension Notification.Name {
    /// Posted (object: Keychain.Key.rawValue) after a key is saved or removed.
    static let naviKeysChanged = Notification.Name("navi.keysChanged")
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
        case nil: return "No Jev key yet — Navi routes with local heuristics until one is added."
        }
    }
}
