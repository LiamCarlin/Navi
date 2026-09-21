import SwiftUI

struct AgentSettingsView: View {
    @EnvironmentObject private var settings: NaviSettings

    var body: some View {
        FormPage(title: "Agent", subtitle: "\"Open Chrome, search for X and click the first result\" — Jev decides, Claude only looks when Jev can't.") {
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
                Text("Driver")
            } footer: {
                Text(settings.agentDriver == .jevFirst
                     ? "Each step: enumerate on-screen controls via Accessibility → one Jev call chooses the operation and target (~100 ms) → execute. Field text comes from Claude Haiku; only NEED_VISION, low confidence or a stuck screen wakes the screenshot loop."
                     : "Every step sends a screenshot to Claude. Slower and costlier, but works on canvas apps and anything Accessibility can't describe.")
            }

            Section("Approval") {
                Picker("Ask me", selection: $settings.agentApprovalMode) {
                    ForEach(ApprovalMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Run tasks in the background", isOn: $settings.agentRunInBackground)
                Text(settings.agentRunInBackground
                     ? "Navi drives the app behind your windows: clicks and keystrokes are delivered straight to that app, screenshots capture only its window, and browser tasks use a background Chrome tab. Your cursor, keyboard and frontmost app stay yours. The exception is ⌘-shortcuts (⌘S, ⌘L…), which macOS only delivers to the active app — Navi brings the app forward for a split second for those and hands focus straight back."
                     : "Navi brings the app to the front and uses the real cursor and keyboard. Best for canvas apps and menus; you'll need to keep your hands off while it works.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show the result when a task finishes", isOn: $settings.agentRevealWhenDone)
                    .disabled(!settings.agentRunInBackground)
                Text("When a background task makes something — a note, an event, a document, a tab — Navi brings that window to the front once it's done. Lookups stay in the background; their answer is in the panel.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("While it works")
            }

            Section("Limits") {
                Stepper(value: $settings.agentMaxSteps, in: 5...200, step: 5) {
                    LabeledContent("Maximum steps per task") {
                        Text("\(settings.agentMaxSteps)").monospacedDigit()
                    }
                }
                Toggle("Show the live overlay while the agent works", isOn: $settings.agentShowLiveOverlay)
                Picker("Model", selection: $settings.agentModel) {
                    ForEach(ProvidersView.claudeModels, id: \.self) { Text($0).tag($0) }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    gate("Irreversible", "send, pay, delete, post",
                         "After every step Jev answers `is_irreversible` from the step log. With \"Ask only for risky actions\" this is the only time you're interrupted.")
                    gate("Prohibited", "credentials, payments, security settings",
                         "Always refused, in every approval mode. Navi hands the task back to you instead.")
                    gate("Stuck", "same screen, no progress",
                         "`is_stuck` and `task_complete` stop the loop early so a confused run doesn't burn steps.")
                }
                .padding(.vertical, 2)
            } header: {
                Text("What Jev gates")
            } footer: {
                Text("Each gate is one System One call (~100 ms) on the textual step log — no extra screenshots, no extra Claude tokens.")
            }

            BrowserRuntimeSection()
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
        if !settings.hasJevKey { s += " No Jev key yet — the Claude-only driver will be used until one is added under AI Providers." }
        return s
    }

    private var modeExplanation: String {
        switch settings.agentApprovalMode {
        case .alwaysAsk: return "Every click and keystroke waits for your OK. Slowest, safest."
        case .askForRisky: return "Jev flags irreversible actions (send, pay, delete) and Navi pauses only for those."
        case .autonomous: return "No prompts. Prohibited categories are still refused."
        }
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
