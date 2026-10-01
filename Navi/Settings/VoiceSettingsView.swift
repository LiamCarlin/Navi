import Speech
import SwiftUI

/// Settings → Voice: how live voice control listens and acts.
struct VoiceSettingsView: View {
    @EnvironmentObject private var settings: NaviSettings
    @StateObject private var permissions = PermissionsModel()
    @State private var modelStatus: String = "Checking…"
    @State private var locales: [Locale] = []
    @State private var resolvedLocale: String = ""
    @State private var voicePrint: VoicePrint? = VoicePrintStore.load()

    var body: some View {
        FormPage(title: "Voice", subtitle: "Talk to Navi. It acts on each instruction the moment it is complete — while you keep talking.") {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(PanelStyle.accentGradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voiceActive ? "Voice control is listening" : "Voice control is off").font(.headline)
                        Text(voiceHint)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(voiceActive ? "Stop" : "Start listening") { AppDelegate.shared?.toggleVoice() }
                }
                .padding(.vertical, 2)
            }

            Section {
                PermissionRow(title: "Microphone",
                              explanation: "Speech is recognized on this Mac by Apple's on-device model. Audio never leaves your Mac.",
                              state: permissions.microphone,
                              request: { Task { _ = await Permissions.requestMicrophone(); await permissions.refresh() } },
                              open: { Permissions.openSettings(.microphone) })
                    .task { await permissions.poll() }
                LabeledContent("Speech model") {
                    Text(modelStatus).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $settings.voiceLocale) {
                    Text("System (\(resolvedLocale.isEmpty ? "…" : resolvedLocale))").tag("")
                    ForEach(locales, id: \.identifier) { l in
                        Text(l.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                    }
                }
                .onChange(of: settings.voiceLocale) { _, _ in Task { await refreshModel() } }
            } header: {
                Text("Listening")
            } footer: {
                Text("The first use of a language downloads its model once (a few hundred MB).")
            }

            Section {
                if let p = voicePrint {
                    Toggle("Only act on my voice", isOn: $settings.voiceOnlyMyVoice)
                    Text(settings.voiceOnlyMyVoice
                         ? "Navi ignores other people talking near your Mac. “Stop” always works, whoever says it."
                         : "Navi acts on any voice it hears.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Your voiceprint") {
                        Text("Learned \(p.created.formatted(date: .abbreviated, time: .omitted)) · updated \(p.updated.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Retrain") { VoiceEnrollmentWindow.show() }
                        Button("Forget my voice", role: .destructive) { VoicePrintStore.delete() }
                    }
                } else {
                    Text("Navi acts on any voice it hears. Read six short lines (about a minute) and it will act only on yours, ignoring anyone else talking nearby.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { VoiceEnrollmentWindow.show() } label: { Label("Teach Navi your voice", systemImage: "person.wave.2") }
                }
            } header: {
                Text("Only my voice")
            } footer: {
                Text("The voiceprint is learned and checked on this Mac, and never leaves it. Takes effect the next time listening starts.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .naviVoicePrintChanged)) { _ in voicePrint = VoicePrintStore.load() }

            Section {
                Toggle("Global shortcut to start talking", isOn: $settings.voiceHotKeyEnabled)
                if settings.voiceHotKeyEnabled {
                    ExplainedRow(title: "Voice shortcut", explanation: "Press it anywhere to start listening; press it again to stop.") {
                        HotKeyRecorderView(kind: .voice)
                    }
                }
                Toggle("Start listening when Navi launches", isOn: $settings.voiceStartsAtLaunch)
            } header: {
                Text("Hands-free")
            } footer: {
                Text("Speech is recognized on this Mac. Navi works out what each instruction means in a fraction of a second.")
            }

            Section {
                Toggle("Bring apps to the front while I talk", isOn: $settings.voiceBringsAppsForward)
                Text(settings.voiceBringsAppsForward
                     ? "Apps you name come forward and Navi uses the real cursor and keyboard, so you watch it happen. Hands off the mouse while it works."
                     : "Apps are driven behind your windows, like a typed task in background mode — you can keep working while Navi acts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Sound cues", isOn: $settings.voiceSounds)
                Toggle("Ignore sound the Mac is playing", isOn: $settings.voiceEchoCancellation)
                Text("Echo cancellation removes what the speakers play from the microphone, and Navi also listens to the Mac's own audio (with the Screen Recording permission) so anything a video says is never taken as an instruction. Takes effect the next time listening starts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: reaction, in: 120...600, step: 20) {
                        Text("Reaction time")
                    } minimumValueLabel: { Text("fast") } maximumValueLabel: { Text("careful") }
                    Text("Navi waits \(reactionSeconds) after your last word before deciding the instruction is complete. Faster feels more immediate; slower avoids acting on half a sentence.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Acting")
            } footer: {
                HStack(spacing: 4) {
                    Text("When Navi asks before acting is set under Tasks. When it asks, say “yes” or “no”, or click in the island.")
                    Button("Open Tasks") { SettingsNavigator.shared.go(.agent) }
                        .buttonStyle(.link)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    how("1", "Listen", "Apple's on-device recognizer streams words as you say them; nothing waits for you to stop talking.")
                    how("2", "Split", "Navi splits what you say at “and”, “then” and pauses into separate instructions.")
                    how("3", "Decide", "For each one Navi decides: is it complete, or is more coming? Should it open an app, do something, search the web or answer? Could it be hard to undo?")
                    how("4", "Act", "Apps launch instantly; tasks run on your Mac; answers stream into the island.")
                }
                .padding(.vertical, 2)
            } header: {
                Text("How it works")
            } footer: {
                Text("Say “stop” to abort, “undo” for ⌘Z, “pause” / “resume”, and “stop listening” to close the island.")
            }
        }
        .task { await loadLocales(); await refreshModel() }
    }

    private var voiceActive: Bool { AppDelegate.shared?.voice?.isListening ?? false }

    /// How to start talking, with the user's own shortcuts.
    private var voiceHint: String {
        let bar = HotKeyManager.describe(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        if settings.voiceHotKeyEnabled {
            let voice = HotKeyManager.describe(keyCode: settings.voiceHotKeyCode, modifiers: settings.voiceHotKeyModifiers)
            return "Press \(voice) anywhere, or click the sparkle in the \(bar) bar."
        }
        return "Click the sparkle in the \(bar) bar, or use the menu bar icon."
    }

    private var reaction: Binding<Double> {
        Binding(get: { Double(settings.voiceReactionMs) }, set: { settings.voiceReactionMs = Int($0) })
    }

    /// "0.3 seconds" — the reaction time in words, not milliseconds.
    private var reactionSeconds: String {
        String(format: "%.1f seconds", Double(settings.voiceReactionMs) / 1000)
    }

    private func how(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadLocales() async {
        let supported = await SpeechTranscriber.supportedLocales
        locales = supported.sorted { ($0.localizedString(forIdentifier: $0.identifier) ?? "") < ($1.localizedString(forIdentifier: $1.identifier) ?? "") }
    }

    private func refreshModel() async {
        let locale = await SpeechListener.resolveLocale(preferred: settings.voiceLocale)
        resolvedLocale = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard SpeechTranscriber.isAvailable else { modelStatus = "Not available on this Mac"; return }
        switch await SpeechListener.modelStatus(for: locale) {
        case .installed: modelStatus = "Installed · \(resolvedLocale)"
        case .downloading: modelStatus = "Downloading…"
        case .supported: modelStatus = "Downloads on first use · \(resolvedLocale)"
        case .unsupported: modelStatus = "Language not supported"
        @unknown default: modelStatus = "Unknown"
        }
    }
}
