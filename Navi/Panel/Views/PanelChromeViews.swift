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
            if vm.isFollowingUp { return "Navi remembers this answer" }
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
        case .schedule:
            return "Navi · schedule"
        case .remind:
            return "Navi · reminder"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 12) {
            switch vm.mode {
            case .results:
                if vm.results.count > 1 { KeyHint(keys: "↑↓", label: "navigate") }
                KeyHint(keys: "⏎", label: PanelWording.primaryVerb(vm.results[safe: vm.selectedIndex]))
                KeyHint(keys: "⌘⏎", label: "ask")
                KeyHint(keys: "esc", label: "clear")
            case .answer:
                if vm.isAnswering {
                    FooterButton(symbol: "stop.fill", title: "Stop", keys: "⌘.", help: "Stop the answer here") { vm.stopAnswer() }
                } else if vm.isFollowingUp {
                    KeyHint(keys: "⏎", label: "ask")
                } else {
                    FooterButton(symbol: "doc.on.doc", title: "Copy", keys: "⌘C", help: "Copy the answer") { vm.copyAnswer() }
                        .disabled(vm.answerText.isEmpty)
                    FooterButton(symbol: "arrow.clockwise", title: "Retry", keys: "⌘R", help: "Ask the same question again") { vm.retryAnswer() }
                        .disabled(vm.answeredQuery.isEmpty)
                    if vm.canFollowUp {
                        FooterButton(symbol: "arrow.turn.down.right", title: "Follow up", keys: "⇥",
                                     help: "Ask something about this answer") { vm.beginFollowUp() }
                    }
                }
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
            case .schedule:
                KeyHint(keys: "↑↓", label: "time")
                KeyHint(keys: "⌘[ ⌘]", label: "day")
                KeyHint(keys: "⌘- ⌘=", label: "length")
                KeyHint(keys: "⏎", label: "book")
                KeyHint(keys: "esc", label: "results")
            case .remind:
                KeyHint(keys: "↑↓", label: "when")
                KeyHint(keys: "⏎", label: "add")
                KeyHint(keys: "esc", label: "results")
            }
        }
    }
}

/// A footer action: symbol, verb and its key cap; brightens on hover.
struct FooterButton: View {
    let symbol: String
    let title: String
    let keys: String
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
                KeyCap(text: keys)
            }
            .foregroundStyle(hover && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(hover && isEnabled ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help ?? title)
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
    /// The fix for an account error ("Sign in", "Upgrade", "Update", "Contact support").
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = .red
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, !actionTitle.isEmpty, let action {
                Button(action: action) {
                    Text(actionTitle).font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.2)))
        .padding(.horizontal, PanelStyle.listPad)
        .padding(.vertical, 8)
    }
}

/// The account's critical banner in the panel (update required, account
/// disabled, an operator's critical notice). Same shape as `ErrorBanner`.
struct AccountNoticeBanner: View {
    let notice: AccountNotice
    @ObservedObject var account: NaviAccount
    var body: some View {
        ErrorBanner(message: notice.message,
                    actionTitle: notice.actionTitle,
                    action: { account.perform(notice) },
                    symbol: notice.kind == .accountDisabled ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.circle.fill",
                    tint: .orange) { account.dismiss(notice) }
    }
}
