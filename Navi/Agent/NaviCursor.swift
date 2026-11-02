import AppKit
import SwiftUI
import Combine

/// The Navi-logo cursor: shows where Navi is clicking, on the window it is working in.
///
/// Every click, scroll and press the agent makes — CGEvents (`InputController`), AX presses
/// (`ActionExecutor`) and the browser runner's CDP clicks (its `pointer` events, read in
/// `UltrafastBridge`) — glides it there and pulses it. It only draws: callers never wait
/// (one hop to the main queue), the panel ignores the mouse, and it sits directly above the
/// driven window in z-order (`order(.above, relativeTo:)`), so in background mode it stays
/// behind whatever the user has in front, exactly like that window. Owned by Navi, so
/// `ScreenCapture` leaves it out of the agent's screenshots. Off with `agentShowsCursor`;
/// hidden when a run ends and after `idleSeconds` without a move.
@MainActor
final class NaviCursor {
    static let shared = NaviCursor()
    nonisolated static let enabledKey = "agentShowsCursor"
    static let idleSeconds: Double = 8

    /// Whose window the point is on.
    enum Owner: Sendable, Equatable {
        case window(CGWindowID)
        case pid(pid_t)
        /// The browser runner's tab: any window of these apps.
        case bundleIDs([String])
        /// HID route (foreground): the topmost window at the point that is not Navi's.
        case anyone
    }

    final class Model: ObservableObject {
        @Published var clicks = 0
    }

    /// Panel side and where the tip sits in it (room for the click ripple around the tip).
    static let panelSize: CGFloat = 64
    static let tipInset: CGFloat = 18

    private let model = Model()
    private var panel: NSPanel?
    private var window: CGWindowID?
    /// Where the current glide ends and when (a click right after its move rides the same glide).
    private var glide: (frame: CGRect, arrives: Date)?
    private var idleTask: Task<Void, Never>?

    nonisolated static var isEnabled: Bool {
        !TestHost.isActive && (UserDefaults.navi.object(forKey: enabledKey) as? Bool ?? true)
    }

    /// From any thread; returns at once. `point` is in global display coordinates
    /// (top-left origin, as CGEvent, AX and the window server use).
    nonisolated static func show(at point: CGPoint, on owner: Owner, clicking: Bool = false) {
        guard isEnabled, point.x.isFinite, point.y.isFinite else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.move(to: point, on: owner, clicking: clicking) } }
    }

    nonisolated static func hide() {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.hideNow() } }
    }

    // MARK: Pure helpers (tested)

    /// The window to sit above: front-to-back `list` (CGWindowListCopyWindowInfo), first
    /// ordinary window (layer 0) containing `point` whose owner is in `pids` (nil = anyone),
    /// never one of `own`'s.
    nonisolated static func windowID(at point: CGPoint, pids: Set<pid_t>?, in list: [[String: Any]], excluding own: pid_t) -> CGWindowID? {
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner != own,
                  pids.map({ $0.contains(owner) }) ?? true,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.contains(point),
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return id
        }
        return nil
    }

    /// The panel frame (Cocoa, bottom-left origin) that puts the tip on `point`
    /// (global, top-left origin; `primaryHeight` = the menu-bar screen's height).
    nonisolated static func panelFrame(tip point: CGPoint, primaryHeight: CGFloat) -> CGRect {
        let y = primaryHeight - point.y
        return CGRect(x: point.x - tipInset, y: y - (panelSize - tipInset), width: panelSize, height: panelSize)
    }

    // MARK: Moving

    private func move(to point: CGPoint, on owner: Owner, clicking: Bool) {
        guard let target = resolve(owner, at: point) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = Self.panelFrame(tip: point, primaryHeight: primaryHeight)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let gliding = panel.isVisible && panel.alphaValue > 0.5 && target == window
        var arrival = 0.0
        if gliding, let glide, glide.frame == frame {
            arrival = max(0, glide.arrives.timeIntervalSinceNow)
        } else if gliding {
            let distance = hypot(frame.minX - panel.frame.minX, frame.minY - panel.frame.minY)
            arrival = min(0.28, 0.1 + Double(distance) / 3000)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = arrival
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: false)
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        panel.order(.above, relativeTo: Int(target))
        window = target
        glide = (frame, Date().addingTimeInterval(arrival))
        if clicking {
            let model = self.model
            DispatchQueue.main.asyncAfter(deadline: .now() + arrival) { model.clicks += 1 }
        }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            self?.hideNow()
        }
    }

    private func resolve(_ owner: Owner, at point: CGPoint) -> CGWindowID? {
        let pids: Set<pid_t>?
        switch owner {
        case .window(let id): return id
        case .pid(let pid): pids = [pid]
        case .bundleIDs(let ids):
            pids = Set(ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier))
        case .anyone: pids = nil
        }
        if let pids, pids.isEmpty { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self.windowID(at: point, pids: pids, in: list, excluding: ProcessInfo.processInfo.processIdentifier)
    }

    private func hideNow() {
        idleTask?.cancel()
        idleTask = nil
        window = nil
        glide = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A move that came in during the fade owns the panel now.
                guard let self, self.window == nil else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let side = Self.panelSize
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .normal          // z-order comes from `order(.above, relativeTo:)`
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: NaviCursorView(model: model))
        return p
    }
}

/// The Navi mark as a pointer: the gradient tile with its sparkle, top-left corner sharp
/// (the tip, at the click point), a ripple from the tip on every click.
struct NaviCursorView: View {
    @ObservedObject var model: NaviCursor.Model
    @State private var ripple = false
    @State private var pressed = false

    private let size: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: 28, height: 28)
                .scaleEffect(ripple ? 1.15 : 0.2)
                .opacity(ripple ? 0 : 0.85)
                .offset(x: NaviCursor.tipInset - 14, y: NaviCursor.tipInset - 14)
            mark
                .scaleEffect(pressed ? 0.82 : 1, anchor: .topLeading)
                .offset(x: NaviCursor.tipInset, y: NaviCursor.tipInset)
        }
        .frame(width: NaviCursor.panelSize, height: NaviCursor.panelSize, alignment: .topLeading)
        .onChange(of: model.clicks) {
            ripple = false
            pressed = true
            withAnimation(.easeOut(duration: 0.45)) { ripple = true }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(0.08)) { pressed = false }
        }
    }

    private var mark: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: size * 0.42,
                                           bottomTrailingRadius: size * 0.42, topTrailingRadius: size * 0.42,
                                           style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.stroke(.white, lineWidth: 1.5)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
    }
}
