import SwiftUI

/// Bottom bar: what Navi is doing on the left ("Thinking…", "Navi · answering"),
/// key hints on the right. Hints depend on the mode. Routing diagnostics only
/// appear here in developer mode (`vm.statusLine`).
struct PanelFooterView: View {
    @EnvironmentObject private var vm: PanelViewModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, PanelStyle.hPad)
        .frame(height: PanelStyle.footerHeight)
        .overlay(alignment: .top) { Hairline() }
    }

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 6) {
            if vm.isRouting {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
            }
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: statusText)
        }
    }

    private var statusText: String {
        switch vm.mode {
        case .answer:
            if vm.isAnswering { return "Navi · answering" }
            return vm.statusLine.isEmpty ? "Navi" : vm.statusLine
        case .agent:
            if vm.pendingApproval != nil { return "Navi will ask before anything irreversible" }
            if vm.agentRun != nil { return "Navi · working" }
            return vm.statusLine.isEmpty ? "Navi" : vm.statusLine
        case .results:
            if !vm.statusLine.isEmpty { return vm.statusLine }
            return vm.isRouting ? "Thinking…" : "Navi"
        case .clarify:
            if vm.clarification == nil { return "Navi · one question" }
            return "Pick one, or keep typing"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 12) {
            switch vm.mode {
            case .results:
                KeyHint(keys: "↑↓", label: "navigate")
                KeyHint(keys: "⏎", label: "open")
                KeyHint(keys: "⌘⏎", label: "ask")
                KeyHint(keys: "esc")
            case .answer:
                Button(action: { vm.copyAnswer() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold))
                        Text("Copy").font(.system(size: 11, weight: .medium))
                        KeyCap(text: "⌘C")
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.answerText.isEmpty)
                .help("Copy the answer")
                KeyHint(keys: "esc", label: "back")
            case .agent:
                if vm.pendingApproval != nil {
                    KeyHint(keys: "⌘⏎", label: "approve")
                    KeyHint(keys: "⌘⌫", label: "deny")
                }
                KeyHint(keys: "esc", label: vm.agentRun != nil ? "hide" : "back")
            case .clarify:
                KeyHint(keys: "↑↓", label: "choose")
                KeyHint(keys: "⏎", label: "answer")
                KeyHint(keys: "esc", label: "back")
            }
        }
    }
}

/// Transient confirmation ("Copied") as a small glass capsule.
struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.green.opacity(0.10)))
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.green.opacity(0.25)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
    }
}

/// Error banner with a dismiss button; part of the flow so the card grows.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.red.opacity(0.2)))
        .padding(.horizontal, PanelStyle.listPad)
        .padding(.vertical, 8)
    }
}
