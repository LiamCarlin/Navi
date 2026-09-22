import Speech
import SwiftUI

/// Settings → Voice: how live voice control listens and acts.
struct VoiceSettingsView: View {
    @EnvironmentObject private var settings: NaviSettings
    @StateObject private var permissions = PermissionsModel()
    @State private var modelStatus: String = "Checking…"
    @State private var locales: [Locale] = []
    @State private var resolvedLocale: String = ""

    var body: some View {
        FormPage(title: "Voice", subtitle: "Click the sparkle in the ⌘Space bar and talk. Navi acts on each instruction the moment it is complete — mid-sentence, while you keep talking.") {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(PanelStyle.accentGradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voiceActive ? "Voice control is listening" : "Voice control is off").font(.headline)
                        Text("Also from the menu bar, or navi://voice from Shortcuts and Raycast.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(voiceActive ? "Stop" : "Start listening") { AppDelegate.shared?.toggleVoice() }
                }
                .padding(.vertical, 2)
            }

            Section {
                PermissionRow(title: "Microphone",
                              explanation: "Speech is recognized on this Mac by Apple's on-device model; audio never leaves the machine and no speech-recognition account is involved.",
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
                Toggle("Bring apps to the front while I talk", isOn: $settings.voiceBringsAppsForward)
                Text(settings.voiceBringsAppsForward
                     ? "Apps you name come forward and Navi uses the real cursor and keyboard, so you watch it happen. Hands off the mouse while it works."
                     : "Apps are driven behind your windows, like a typed task in background mode — you can keep working while Navi acts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Sound cues", isOn: $settings.voiceSounds)
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
                Text("Risky steps (sending, paying, deleting) still pause for approval — say “yes” or “no”, or click in the island. Approval mode is under Agent.")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    how("1", "Listen", "Apple's on-device recognizer streams words as you say them; nothing waits for you to stop talking.")
                    how("2", "Segment", "Navi splits the stream at “and”, “then” and pauses into candidate instructions.")
                    how("3", "Decide", "For each candidate Navi decides: complete, or still coming? Open an app, do something, browse, answer, or a word for Navi? Which app, and could it be hard to undo?")
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
