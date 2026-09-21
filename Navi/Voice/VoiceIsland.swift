import AppKit
import Combine
import SwiftUI

/// The voice-control "island": a black shape that drops out of the notch
/// (or hangs from the top edge on screens without one) while Navi listens.
///
/// A fixed, fully transparent, non-activating panel sits at the top centre of
/// the screen with the notch; the SwiftUI island is drawn at its top and
/// animates its own size, so the window never resizes and the seam with the
/// notch never moves. Clicks in the transparent part fall through to whatever
/// is underneath; the island itself takes clicks (pause, stop, approvals)
/// without ever becoming key, so the app the user is talking to stays active.
@MainActor
final class VoiceIslandController {
    let session: VoiceSession
    private var panel: NSPanel?
    private let model = IslandModel()
    private var cancellables: Set<AnyCancellable> = []
    private var idleObserver: NSObjectProtocol?

    /// Window size: room for the widest island and a streamed answer.
    static let windowSize = NSSize(width: 680, height: 480)

    init(session: VoiceSession) {
        self.session = session
        idleObserver = NotificationCenter.default.addObserver(forName: .naviVoiceIdle, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfIdle() }
        }
        session.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard let self else { return }
            if phase == .off { self.hideIfIdle() }
            NotificationCenter.default.post(name: .naviVoiceStateChanged, object: nil)
        }.store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isListening: Bool { session.phase.isActive }

    /// Start listening and show the island (or stop when already listening).
    func toggle() {
        if session.phase.isActive { stop() } else { start() }
    }

    func start(audioFile: URL? = nil) {
        show()
        session.start(audioFile: audioFile)
    }

    func stop() {
        session.stop()
        hideIfIdle()
    }

    // MARK: Window

    private func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let screen = Self.targetScreen()
        model.metrics = IslandMetrics(screen: screen)
        position(on: screen)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        withAnimation(IslandStyle.appear) { model.visible = true }
    }

    private func hideIfIdle() {
        guard session.phase == .off, !session.isBusy, let panel, panel.isVisible else { return }
        withAnimation(IslandStyle.disappear) { model.visible = false }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.session.phase == .off, !self.session.isBusy else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                  // the island draws its own
        // Above the menu bar (24) and status items (25): the collar sits in the menu-bar band beside the notch.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.titleVisibility = .hidden
        p.becomesKeyOnlyIfNeeded = true
        let root = VoiceIslandView(session: session, model: model,
                                   onStop: { [weak self] in self?.stop() },
                                   onTogglePause: { [weak self] in self?.session.togglePause() })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// The screen with the notch (built-in display) when there is one; else
    /// the screen with the mouse.
    static func targetScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func position(on screen: NSScreen) {
        guard let panel else { return }
        let m = model.metrics
        let size = Self.windowSize
        let x = (m.notchCenterX - size.width / 2).rounded()
        let y = screen.frame.maxY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Non-activating and never main; with `becomesKeyOnlyIfNeeded` it only takes
/// key status for a control that needs the keyboard (none today), so the app
/// the user is talking to keeps focus while its buttons still take clicks.
final class IslandPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}

// MARK: - Metrics

/// Where the notch is on the target screen, in the island window's terms.
struct IslandMetrics: Equatable {
    /// Height of the band the island shares with the notch (0 without a notch).
    var collarHeight: CGFloat
    /// Width of the notch cut-out (a default when the screen has none).
    var notchWidth: CGFloat
    var hasNotch: Bool
    /// Screen x of the notch centre (screen centre without a notch).
    var notchCenterX: CGFloat

    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        hasNotch = inset > 0
        collarHeight = hasNotch ? inset : 0
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(120, right.minX - left.maxX)
            notchCenterX = (left.maxX + right.minX) / 2
        } else {
            notchWidth = 196
            notchCenterX = screen.frame.midX
        }
    }

    static let fallback = IslandMetrics(collarHeight: 0, notchWidth: 196, hasNotch: false, notchCenterX: 0)
    private init(collarHeight: CGFloat, notchWidth: CGFloat, hasNotch: Bool, notchCenterX: CGFloat) {
        self.collarHeight = collarHeight; self.notchWidth = notchWidth; self.hasNotch = hasNotch; self.notchCenterX = notchCenterX
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var visible = false
    @Published var metrics: IslandMetrics = .fallback
}

enum IslandStyle {
    static let appear = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let disappear = Animation.spring(response: 0.3, dampingFraction: 0.9)
    static let resize = Animation.spring(response: 0.36, dampingFraction: 0.82)
    static let bottomRadius: CGFloat = 24
    static let fillet: CGFloat = 12
    static let hPad: CGFloat = 18
    static let compactWidth: CGFloat = 340
    static let wideWidth: CGFloat = 460
    static let answerWidth: CGFloat = 560
    static let maxAnswerHeight: CGFloat = 260
}

// MARK: - Shape

/// Bottom corners rounded, top corners flared outward so the island reads as
/// part of the notch (the flares sit in the menu-bar band beside it).
struct IslandShape: InsettableShape {
    var bottomRadius: CGFloat = IslandStyle.bottomRadius
    var fillet: CGFloat = IslandStyle.fillet
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandShape {
        var s = self
        s.inset += amount
        return s
    }

    func path(in outer: CGRect) -> Path {
        let rect = outer.insetBy(dx: inset, dy: inset)
        let w = rect.width, h = rect.height
        let t = min(fillet, w / 4)
        let r = min(bottomRadius, (w - 2 * t) / 2, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + t + r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - t - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        _ = h
        return p
    }
}
