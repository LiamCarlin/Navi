import AppKit
import SwiftUI
import Combine

/// Small non-activating floating pill at the bottom-right of the screen while
/// the computer-use agent runs: "Navi is working… step 3/40 · Stop".
/// Owned by Navi, so `ScreenCapture` excludes it from frames automatically.
///
/// In background mode it is the only sign that anything is happening (the
/// driven app stays behind the user's windows), so it names the mode and
/// lingers on the outcome for a few seconds after the run ends.
@MainActor
final class AgentOverlay {
    enum Outcome { case completed, failed, cancelled }

    final class Model: ObservableObject {
        @Published var text: String = "Navi is working…"
        @Published var waitingForApproval = false
        @Published var outcome: Outcome?
        var onStop: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?
    private let background: Bool
    private var hideTask: Task<Void, Never>?
    static let lingerSeconds: Double = 6

    init(onStop: @escaping () -> Void, background: Bool = false) {
        model.onStop = onStop
        self.background = background
    }

    private var working: String { background ? "Navi is working in the background…" : "Navi is working…" }

    /// Also shown for browser steps (which run in their own Chrome tab); the
    /// pill is the one thing that stays visible after the panel hides.
    func show(step: Int, maxSteps: Int) {
        update(step: step, maxSteps: maxSteps)
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func update(step: Int, maxSteps: Int, status: String? = nil) {
        model.waitingForApproval = false
        model.outcome = nil
        if let status, !status.isEmpty {
            model.text = "\(status) · \(step)/\(maxSteps)"
        } else {
            model.text = "\(working) step \(step)/\(maxSteps)"
        }
    }

    /// Shows how the run ended and hides itself after `lingerSeconds`. The
    /// user may have been looking elsewhere the whole time; this is their
    /// cue to press "Show" for the details.
    func finish(_ outcome: Outcome, text: String) {
        guard panel != nil else { return }
        model.waitingForApproval = false
        model.outcome = outcome
        let one = text.replacingOccurrences(of: "\n", with: " ")
        model.text = one.count > 90 ? String(one.prefix(90)) + "…" : one
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lingerSeconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func setWaitingForApproval() {
        model.waitingForApproval = true
        model.text = "Waiting for your approval in Navi"
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.titleVisibility = .hidden
        let host = NSHostingView(rootView: AgentOverlayView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }

    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: vf.maxX - size.width - 16, y: vf.minY + 16)
        panel.setFrameOrigin(origin)
    }
}

struct AgentOverlayView: View {
    @ObservedObject var model: AgentOverlay.Model

    var body: some View {
        HStack(spacing: 10) {
            if model.waitingForApproval {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            } else if let outcome = model.outcome {
                switch outcome {
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 420)
            Divider().frame(height: 14)
            Button {
                NotificationCenter.default.post(name: .naviShowCurrentTask, object: nil)
            } label: {
                Text("Show").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the task in Navi")
            if model.outcome == nil {
                Divider().frame(height: 14)
                Button {
                    model.onStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}
