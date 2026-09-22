import SwiftUI

/// Settings → Agent → "Browser tasks": status and one-click setup for the
/// jev-ultrafast runtime (Browser Use × TypeSafe) that drives Chrome.
struct BrowserRuntimeSection: View {
    @State private var runtime: UltrafastBridge.RuntimeStatus? = nil
    @State private var chrome: UltrafastBridge.ChromeStatus? = nil
    @State private var busy = false
    @State private var log = ""
    @AppStorage("ultrafastScreenshots") private var screenshots = false
    @AppStorage("ultrafastTextModel") private var textModel = "claude-haiku-4-5"
    @AppStorage("ultrafastEnabled") private var enabled = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use the Chrome runner when Chrome is the browser")
                    Text("Web tasks otherwise run on Jev's native driver in whatever browser is in front — Safari, Arc, Firefox, Chrome — from its accessibility tree. Nothing to install; the runner is a faster, DOM-level path for Chrome only.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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
            Text("With the runner, one Jev request per step picks the operation and the exact DOM element in a background Chrome tab (Google Flights search: ~7 s end to end). Without it — or in any other browser — the same Jev loop reads the page through Accessibility instead.")
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
