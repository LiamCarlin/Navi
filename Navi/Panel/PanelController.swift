import AppKit
import SwiftUI

/// Floating, non-activating Spotlight-style panel. Centered on the screen with
/// the mouse, sized 680×(dynamic). Dismisses on ⎋, click-outside, or after an
/// action. The SwiftUI content lives in `Panel/Views/NaviPanelView.swift`.
@MainActor
final class PanelController {
    let panel: NaviPanel
    let viewModel: PanelViewModel
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var previousApp: NSRunningApplication?

    /// Width of the glass card (Spotlight's width).
    static let width: CGFloat = 680
    /// Transparent margin around the card inside the window. The card's soft
    /// drop shadow is drawn by SwiftUI in this margin (the window's own shadow
    /// is off because it would be computed for the rectangular window).
    static let shadowInsets = NSEdgeInsets(top: PanelStyle.shadowInsets.top, left: PanelStyle.shadowInsets.leading,
                                           bottom: PanelStyle.shadowInsets.bottom, right: PanelStyle.shadowInsets.trailing)

    init(services: NaviServices) {
        viewModel = PanelViewModel(services: services)
        panel = NaviPanel(contentRect: NSRect(x: 0, y: 0,
                                             width: Self.width + Self.shadowInsets.left + Self.shadowInsets.right,
                                             height: 64 + Self.shadowInsets.top + Self.shadowInsets.bottom))
        let root = NaviPanelView()
            .environmentObject(viewModel)
            .environmentObject(NaviSettings.shared)
        let host = NSHostingView(rootView: root)
        // The SwiftUI root measures its own height (`onContentHeightChange`) and
        // we size the panel from that, so AppKit must not also fight over the
        // frame via intrinsic-size constraints (which would grow it upwards).
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        viewModel.onDismiss = { [weak self] in self?.hide() }
        viewModel.onContentHeightChange = { [weak self] h in self?.position(contentHeight: h) }
        panel.onResignKey = { [weak self] in self?.hide() }
    }

    /// Last height reported by the SwiftUI root (the glass card), in points.
    private var contentHeight: CGFloat = 64

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(prefill: String? = nil, submit: Bool = false) {
        previousApp = NSWorkspace.shared.frontmostApplication
        let ctx = ContextProbe.current(recent: [])
        viewModel.willShow(prefill: prefill, context: ctx)
        applyAppearance()
        position()
        panel.alphaValue = 0
        // Non-activating: the panel takes key focus but the previous app stays active.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
        if submit, let prefill, !prefill.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                viewModel.performSelected()
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.viewModel.reset()
            // If something activated Navi (e.g. the settings window), hand focus back.
            if NSApp.isActive, let app = self.previousApp, app != NSRunningApplication.current,
               !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue == WindowID.main }) {
                app.activate()
            }
        })
    }

    /// Mirrors `NaviSettings.appearance` onto the panel so the glass, text and
    /// vibrancy all follow the chosen scheme (the SwiftUI root also sets
    /// `preferredColorScheme`).
    private func applyAppearance() {
        switch NaviSettings.shared.appearance {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Re-center after content height changes (results/answer expand).
    func position() {
        position(contentHeight: contentHeight)
    }

    /// Sizes the panel to `contentHeight` (as measured by the SwiftUI root) and
    /// keeps its top edge pinned at ~22 % from the top of the screen under the
    /// mouse. Called on every frame of the card's spring animation, so it must
    /// stay cheap and must not animate on its own.
    func position(contentHeight newHeight: CGFloat) {
        contentHeight = max(64, newHeight.rounded(.up))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let ins = Self.shadowInsets
        let cardH = min(contentHeight, vis.height * 0.78)
        let w = Self.width + ins.left + ins.right
        let h = cardH + ins.top + ins.bottom
        let x = (vis.midX - Self.width / 2 - ins.left).rounded()
        // Spotlight sits at ~ 1/5 from the top (that is where the card's top edge goes).
        let cardTop = (vis.maxY - vis.height * 0.22).rounded()
        let y = cardTop + ins.top - h
        let frame = NSRect(x: x, y: max(vis.minY - ins.bottom, y), width: w, height: h)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            let vm = self.viewModel
            let cmd = ev.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            switch ev.keyCode {
            case 53: vm.escape(); return nil                               // esc
            case 125: vm.moveSelection(1); return nil                      // down
            case 126: vm.moveSelection(-1); return nil                     // up
            case 36, 76:                                                   // return / enter
                if cmd {
                    // ⌘⏎: approve a pending agent action, else ask Navi with the raw query.
                    if vm.pendingApproval != nil { vm.approvePending(true) }
                    else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty { vm.askNavi(vm.query) }
                } else {
                    vm.performSelected()
                }
                return nil
            case 51 where cmd && vm.pendingApproval != nil:                // ⌘⌫: deny
                vm.approvePending(false); return nil
            case 8 where cmd && vm.mode == .answer:                        // ⌘C in answer mode: copy the answer
                if vm.copyAnswer() { return nil }
                return ev
            case 43 where cmd:                                             // ⌘,
                AppDelegate.shared?.openMainWindow(); self.hide(); return nil
            default: return ev
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
}

/// Borderless floating panel that can become key (for the text field) but
/// never becomes the main window and never shows in the Dock/⌘Tab.
final class NaviPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the SwiftUI card draws its own soft shadow (see PanelController.shadowInsets)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Reads the frontmost app / window / selection at the moment the panel opens.
enum ContextProbe {
    @MainActor
    static func current(recent: [String]) -> QueryContext {
        let app = NSWorkspace.shared.frontmostApplication
        var title: String?
        if let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success, let win {
                var t: CFTypeRef?
                if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                    title = t as? String
                }
            }
        }
        return QueryContext(frontmostApp: app?.bundleIdentifier,
                            frontmostAppName: app?.localizedName,
                            frontmostWindowTitle: title,
                            selectedText: nil,
                            clipboard: NSPasteboard.general.string(forType: .string).map { String($0.prefix(2000)) },
                            recentQueries: recent,
                            timestamp: Date())
    }
}
