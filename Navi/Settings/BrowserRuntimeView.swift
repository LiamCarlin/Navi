import SwiftUI

/// Settings → Agent → "Browser tasks": status and one-click setup for the
/// jev-ultrafast runtime (Browser Use × TypeSafe) that drives Chrome.
struct BrowserRuntimeSection: View {
    @State private var runtime: UltrafastBridge.RuntimeStatus? = nil
    @State private var chrome: UltrafastBridge.ChromeStatus? = nil
    @State private var busy = false
    @State private var log = ""
    @AppStorage("ultrafastScreenshots") private var screenshots = true
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
            Toggle("Stream page screenshots to the panel", isOn: $screenshots)
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
