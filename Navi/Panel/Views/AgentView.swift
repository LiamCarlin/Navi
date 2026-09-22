import SwiftUI

/// Live computer-use run: task header, step timeline, screenshot thumbnail,
/// and the approval card when an action looks irreversible. Engine chatter in
/// the timeline (vendor names, latencies, probabilities) is hidden unless
/// developer mode is on — see `PanelWording`.
struct AgentView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @State private var timelineHeight: CGFloat = 0

    private var isRunning: Bool { vm.agentRun != nil }

    private var taskTitle: String {
        if let t = vm.agentRun?.task, !t.isEmpty { return t }
        if !vm.agentTaskTitle.isEmpty { return vm.agentTaskTitle }
        let q = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? "Task" : q
    }

    private var outcome: AgentEvent? {
        vm.agentEvents.last {
            switch $0 {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    private var stepCount: Int {
        vm.agentEvents.reduce(0) { if case .step = $1 { return $0 + 1 } else { return $0 } }
    }

    /// Index (in `agentEvents`) of the most recent `.step`; that row gets the live dot.
    private var lastStepIndex: Int? {
        vm.agentEvents.lastIndex { if case .step = $0 { return true } else { return false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                timeline
                if let shot = vm.agentScreenshot {
                    ScreenshotThumbnail(image: shot, live: isRunning)
                        .frame(width: 200)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            if let p = vm.pendingApproval {
                ApprovalCard(description: p.description,
                             risk: DeveloperMode.isEnabled ? p.risk : PanelWording.userFacing(p.risk),
                             approve: { vm.approvePending(true) },
                             deny: { vm.approvePending(false) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, PanelStyle.hPad)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .animation(PanelStyle.spring, value: vm.pendingApproval?.id)
        .animation(PanelStyle.spring, value: vm.agentScreenshot == nil)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentStatusChip(isRunning: isRunning, outcome: outcome, awaitingApproval: vm.pendingApproval != nil)
            Text(taskTitle)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if stepCount > 0 {
                Text("\(stepCount) step\(stepCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if isRunning {
                Button(action: { vm.cancelAgent() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        Text("Stop")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .help("Stop the agent (esc)")
            }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(vm.agentEvents.enumerated()), id: \.offset) { idx, ev in
                        AgentEventRow(event: ev,
                                      isLatest: idx == lastStepIndex && outcome == nil,
                                      isRunning: isRunning,
                                      isLast: idx == vm.agentEvents.count - 1)
                    }
                    if vm.agentEvents.isEmpty {
                        HStack(spacing: 8) {
                            StreamingCaret()
                            Text(isRunning ? "Starting…" : "No activity yet")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timelineHeight = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(max(timelineHeight, 40), PanelStyle.maxScrollHeight - 80))
            .onChange(of: vm.agentEvents.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("agent-bottom", anchor: .bottom) }
            }
        }
    }
}

// MARK: - Pieces

struct AgentStatusChip: View {
    let isRunning: Bool
    let outcome: AgentEvent?
    let awaitingApproval: Bool

    private var color: Color {
        if awaitingApproval { return .orange }
        switch outcome {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        default: return isRunning ? .pink : .gray
        }
    }

    private var symbol: String {
        if awaitingApproval { return "hand.raised.fill" }
        switch outcome {
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .cancelled: return "minus"
        default: return "cursorarrow.motionlines"
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            if isRunning && outcome == nil && !awaitingApproval {
                Circle().strokeBorder(color.opacity(0.45), lineWidth: 1.5)
            }
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isRunning && outcome == nil)
        }
        .frame(width: 24, height: 24)
    }
}

struct AgentEventRow: View {
    let event: AgentEvent
    let isLatest: Bool
    let isRunning: Bool
    let isLast: Bool

    var body: some View {
        switch event {
        case .planned(let plan):
            card(tint: .indigo, icon: "list.bullet.clipboard") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plan").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.indigo)
                    Text(plan).font(.system(size: 13).italic()).foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(2.5)
                }
            }
        case .step(let index, let description):
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    StepDot(number: index, active: isLatest && isRunning)
                    if !isLast {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 22)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(isLatest && isRunning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineSpacing(2)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .status(let s):
            if DeveloperMode.isEnabled {
                statusRow(s)
            } else if !PanelWording.isDiagnostic(s) {
                statusRow(PanelWording.userFacing(s))
            }
        case .needsApproval(_, let description, _):
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Text("Asked for approval · \(description)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.leading, 6)
            .padding(.bottom, 8)
        case .completed(let summary):
            card(tint: .green, icon: "checkmark.circle.fill") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Done").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.green)
                    Text(summary).font(.system(size: 13)).lineSpacing(2.5)
                }
            }
        case .failed(let message):
            card(tint: .red, icon: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Failed").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.red)
                    Text(DeveloperMode.isEnabled ? message : PanelWording.userFacing(message))
                        .font(.system(size: 13)).lineSpacing(2.5)
                }
            }
        case .cancelled:
            card(tint: .gray, icon: "stop.circle.fill") {
                Text("Cancelled").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
        case .screenshot:
            EmptyView()
        }
    }

    private func statusRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.leading, 32)
            .padding(.bottom, 8)
    }

    private func card<C: View>(tint: Color, icon: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.16)))
        .padding(.bottom, 10)
    }
}

/// Numbered timeline dot; the active one breathes.
struct StepDot: View {
    let number: Int
    let active: Bool
    var body: some View {
        ZStack {
            if active {
                BreathingHalo(color: .pink)
                    .frame(width: 22, height: 22)
            }
            Circle()
                .fill(active ? AnyShapeStyle(PanelStyle.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.10)))
                .frame(width: 18, height: 18)
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(active ? .white : .secondary)
        }
        .frame(width: 22, height: 22)
    }
}

/// Soft halo that breathes behind the active step dot.
struct BreathingHalo: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let k = (sin(t * 2.4) + 1) / 2          // 0…1
            Circle()
                .fill(color.opacity(0.10 + 0.14 * k))
                .scaleEffect(0.9 + 0.2 * k)
        }
    }
}

struct ScreenshotThumbnail: View {
    let image: NSImage
    let live: Bool
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
                if live {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Text("LIVE").font(.system(size: 8.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// "Approve (⌘⏎) / Deny (⌘⌫)" card for an action that looks irreversible.
struct ApprovalCard: View {
    let description: String
    let risk: String
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Navi wants to: \(description)")
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(2)
                    if !risk.isEmpty {
                        Text(risk)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(action: deny) {
                    HStack(spacing: 6) {
                        Text("Deny")
                        KeyCap(text: "⌘⌫")
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                Button(action: approve) {
                    HStack(spacing: 6) {
                        Text("Approve")
                        Text("⌘⏎").font(.system(size: 10.5, weight: .semibold, design: .rounded)).opacity(0.8)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.22)))
    }
}
