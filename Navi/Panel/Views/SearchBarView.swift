import SwiftUI

/// The 64 pt search row: sparkle glyph · big light text field · intent pill.
struct SearchBarView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @FocusState private var isFocused: Bool
    @State private var hintIndex = 0

    /// Shown while the query is empty; cycles every few seconds.
    private static let hints = [
        "Open Maps",
        "What's on my calendar?",
        "Open Chrome and search for…",
        "What was I working on yesterday?",
        "12% of 340",
        "Toggle dark mode",
    ]

    var body: some View {
        HStack(spacing: 14) {
            // Navi's sparkle doubles as the voice button: click it and the
            // island drops out of the notch and starts listening.
            VoiceButton(isRouting: vm.isRouting, isAnswering: vm.isAnswering, isAgent: vm.agentRun != nil) {
                vm.startVoice()
            }
            .frame(width: 26, height: 26)

            ZStack(alignment: .leading) {
                if vm.query.isEmpty {
                    Text(Self.hints[hintIndex])
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .id(hintIndex)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                        .allowsHitTesting(false)
                }
                TextField("", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .light))
                    .tint(.indigo)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .lineLimit(1)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.45), value: hintIndex)

            trailingSlot
        }
        .padding(.horizontal, PanelStyle.hPad)
        .frame(height: PanelStyle.barHeight)
        .task(id: "hint-cycle") { await cycleHints() }
        .onChange(of: vm.focusRequestID, initial: true) { _, _ in focus() }
        .onAppear { focus() }
    }

    /// Right side of the bar: a toast (when the panel is bar-only), otherwise
    /// the intent Jev decided.
    @ViewBuilder
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            if let toast = vm.toast, !vm.hasContent {
                ToastPill(text: toast)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            } else if let d = vm.decision, !vm.query.isEmpty {
                IntentPill(decision: d)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            }
        }
        .animation(PanelStyle.pillSpring, value: vm.decision?.intent)
        .animation(PanelStyle.pillSpring, value: vm.decision?.source)
        .animation(PanelStyle.pillSpring, value: vm.toast)
    }

    private func focus() {
        guard vm.mode != .clarify else { return }   // the follow-up's text box owns focus
        isFocused = true
        // The panel becomes key a run-loop turn after `willShow`; ask again then.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            if vm.mode != .clarify { isFocused = true }
        }
    }

    private func cycleHints() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled else { return }
            if vm.query.isEmpty {
                hintIndex = (hintIndex + 1) % Self.hints.count
            }
        }
    }
}

// MARK: - Voice button

/// The sparkle, clickable. Hovering swaps in a waveform so the affordance is
/// discoverable; the tooltip says what it does.
struct VoiceButton: View {
    var isRouting: Bool
    var isAnswering: Bool
    var isAgent: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(PanelStyle.accentGradient.opacity(hover ? 0.16 : 0))
                    .frame(width: 34, height: 34)
                if hover {
                    Image(systemName: "waveform")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(PanelStyle.accentGradient)
                        .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: true)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    SparkleGlyph(isRouting: isRouting, isAnswering: isAnswering, isAgent: isAgent)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(PanelStyle.quickSpring, value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Talk to Navi — voice control")
        .accessibilityLabel("Start voice control")
    }
}

// MARK: - Sparkle

/// Navi's sparkle. Rotates gently while Jev is routing, pulses while an answer streams.
struct SparkleGlyph: View {
    var isRouting: Bool
    var isAnswering: Bool
    var isAgent: Bool = false

    var body: some View {
        Image(systemName: isAgent ? "sparkles" : "sparkle")
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(PanelStyle.accentGradient)
            .symbolEffect(.rotate.byLayer, options: .repeat(.continuous).speed(0.55), isActive: isRouting)
            .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isAnswering)
            .shadow(color: .purple.opacity(isAnswering ? 0.45 : 0.18), radius: isAnswering ? 8 : 4)
            .animation(.easeInOut(duration: 0.4), value: isAnswering)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel("Navi")
    }
}

// MARK: - Pills

/// "Open app · 92%" — or a muted "local" pill when the heuristic router decided.
struct IntentPill: View {
    let decision: RouteDecision

    private var tint: Color {
        switch decision.intent {
        case .askQuestion: return .purple
        case .computerTask: return .pink
        case .recallMemory: return .indigo
        case .calculate: return .orange
        case .openApp, .openFile, .openURL: return .blue
        case .webSearch: return .mint
        case .systemCommand, .settings: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if decision.source == .heuristic {
                Image(systemName: "cpu").font(.system(size: 9, weight: .bold))
                Text("local")
            } else {
                if decision.isRisky {
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 9, weight: .bold))
                }
                Text(decision.intent.displayName)
                Text("·").foregroundStyle(.tertiary)
                Text("\(percent)%").monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(decision.source == .heuristic ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(decision.source == .heuristic ? Color.primary.opacity(0.06) : tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(decision.source == .heuristic ? Color.primary.opacity(0.08) : tint.opacity(0.28)))
        .fixedSize()
        .help(decision.source == .heuristic
              ? "Decided locally (Jev unavailable)"
              : "Jev · \(decision.intent.displayName) · \(percent)% · \(decision.latencyMs) ms")
    }

    private var percent: Int {
        Int(((decision.probabilities[decision.intent] ?? decision.confidence) * 100).rounded())
    }
}

/// Small green "✓ Copied" pill for the bar-only layout.
struct ToastPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.green.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Color.green.opacity(0.28)))
        .fixedSize()
    }
}
