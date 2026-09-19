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

    static let width: CGFloat = 680

    init(services: NaviServices) {
        viewModel = PanelViewModel(services: services)
        panel = NaviPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64))
        let root = NaviPanelView()
            .environmentObject(viewModel)
            .environmentObject(NaviSettings.shared)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        viewModel.onDismiss = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(prefill: String? = nil, submit: Bool = false) {
        previousApp = NSWorkspace.shared.frontmostApplication
        let ctx = ContextProbe.current(recent: [])
        viewModel.willShow(prefill: prefill, context: ctx)
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
               !NSApp.windows.contains(where: { $0.isVisible && AppActivation.isMainWindow($0) }) {
                app.activate()
            }
        })
    }

    /// Re-center after content height changes (results/answer expand).
    func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? NSSize(width: Self.width, height: 64)
        let h = max(64, size.height)
        let x = vis.midX - Self.width / 2
        // Spotlight sits at ~ 1/5 from the top.
        let y = vis.maxY - vis.height * 0.22 - h
        panel.setFrame(NSRect(x: x, y: max(vis.minY, y), width: Self.width, height: h), display: true, animate: false)
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            switch ev.keyCode {
            case 53: self.viewModel.escape(); return nil                  // esc
            case 125: self.viewModel.moveSelection(1); return nil          // down
            case 126: self.viewModel.moveSelection(-1); return nil         // up
            case 36, 76:                                                   // return / enter
                self.viewModel.performSelected(); return nil
            case 43 where ev.modifierFlags.contains(.command):             // ⌘,
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
        hasShadow = true
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
