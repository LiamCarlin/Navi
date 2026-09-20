import AppKit
import SwiftUI
import Combine

/// Small non-activating floating pill at the bottom-right of the screen while
/// the computer-use agent runs: "Navi is working… step 3/40 · Stop".
/// Owned by Navi, so `ScreenCapture` excludes it from frames automatically.
@MainActor
final class AgentOverlay {
    final class Model: ObservableObject {
        @Published var text: String = "Navi is working…"
        @Published var waitingForApproval = false
        var onStop: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?

    init(onStop: @escaping () -> Void) {
        model.onStop = onStop
    }

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
        if let status, !status.isEmpty {
            model.text = "\(status) · \(step)/\(maxSteps)"
        } else {
            model.text = "Navi is working… step \(step)/\(maxSteps)"
        }
    }

    func setWaitingForApproval() {
        model.waitingForApproval = true
        model.text = "Waiting for your approval in Navi"
    }

    func hide() {
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
            } else {
                ProgressView().controlSize(.small)
            }
            Text(model.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Divider().frame(height: 14)
            Button {
                NotificationCenter.default.post(name: .naviShowCurrentTask, object: nil)
            } label: {
                Text("Show").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the task in Navi")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}
