import SwiftUI

/// Settings → Tasks (the agent): when Navi asks before acting, and whether it
/// works behind your windows. Engine tuning (driver, confidence threshold, fallback
/// budget, model) lives in the Developer section.
struct AgentSettingsView: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        FormPage(title: "Tasks", subtitle: "Say what to do — \u{201C}open Chrome, search for X and click the first result\u{201D} — and Navi does it on your Mac.") {
            Section {
                Picker("Ask me", selection: $settings.agentApprovalMode) {
                    ForEach(ApprovalMode.allCases) { Text(Self.label(for: $0)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                caption(modeExplanation)
            } header: {
                Text("Approval")
            } footer: {
                Text("Whatever you choose, Navi never enters passwords or payment details and never changes security settings — it hands those back to you.")
            }

            Section {
                Toggle("Work in the background", isOn: $settings.agentRunInBackground)
                caption(settings.agentRunInBackground
                        ? "Navi works in the app behind your windows, so your cursor, keyboard and front app stay yours. For shortcuts like ⌘S the app comes forward for a split second."
                        : "Navi brings the app to the front and uses the real cursor and keyboard. Best for drawing apps and menus — keep your hands off while it works.")
                Toggle("Show the result when a task finishes", isOn: $settings.agentRevealWhenDone)
                    .disabled(!settings.agentRunInBackground)
                caption("When a background task makes something — a note, an event, a document — Navi brings that window forward once it's done. Answers to questions stay in the panel.")
                Toggle("Show progress on screen while Navi works", isOn: $settings.agentShowLiveOverlay)
                Stepper(value: $settings.agentMaxSteps, in: 5...200, step: 5) {
                    LabeledContent("Give up after") {
                        Text("\(settings.agentMaxSteps) steps").monospacedDigit()
                    }
                }
            } header: {
                Text("While it works")
            }

            Section {
                Toggle("Do things the way I do", isOn: $settings.agentUsesScreenHabits)
                caption("Navi uses Recall to pick the apps and sites you actually use, the app you talk to each person in, and where your projects and documents live. Only names, page titles and links are used — never the text on your screen.")
            } header: {
                Text("Your habits")
            }

            Section {
                Toggle("Typing sounds", isOn: $settings.agentTypingSounds)
                HStack {
                    Slider(value: $settings.agentTypingSoundsVolume, in: 0.05...1) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    Button("Preview") { TypingSoundPlayer.shared.preview() }
                }
                .disabled(!settings.agentTypingSounds)
                caption("Soft key clicks while Navi types for you, so you can hear it working behind your windows. Your own typing never makes a sound.")
            } header: {
                Text("Sound")
            }

            Section {
                Toggle("Approve Chrome's connection prompt for me", isOn: $settings.agentAutoApproveChrome)
                caption("Chrome asks \u{201C}Allow remote debugging?\u{201D} each time Navi reconnects — after your Mac sleeps or Chrome restarts. Navi clicks Allow only for its own connection.")
                Toggle("Hide Chrome's \u{201C}automated test software\u{201D} bar", isOn: $settings.agentHideChromeAutomationBar)
                caption("Chrome shows this bar while Navi is connected. Navi closes it as soon as it appears.")
            } header: {
                Text("Google Chrome")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Plain wording for the approval modes (the enum's own labels are engine-facing).
    static func label(for mode: ApprovalMode) -> String {
        switch mode {
        case .askForRisky: return "Ask before risky actions"
        case .alwaysAsk: return "Ask before every step"
        case .autonomous: return "Never ask"
        }
    }

    private var modeExplanation: String { Self.explanation(for: settings.agentApprovalMode) }

    static func explanation(for mode: ApprovalMode) -> String {
        switch mode {
        case .alwaysAsk: return "Every click and keystroke waits for your OK. Slowest, safest."
        case .askForRisky: return "Navi pauses only before something hard to undo — sending, paying, deleting, posting."
        case .autonomous: return "No prompts. Passwords, payments and security settings are still off-limits."
        }
    }
}
