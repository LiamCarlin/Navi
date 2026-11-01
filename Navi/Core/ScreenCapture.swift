import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Shared screenshot helper (ScreenCaptureKit). Used by the computer-use agent
/// (full-res frames sent to Claude) and the memory service (periodic snapshots).
///
/// Requires the Screen Recording permission. `hasPermission` is a cheap
/// preflight; `requestPermission()` triggers the system prompt once.
enum ScreenCapture {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let display: SCDisplay
        /// Points → pixels factor for this display (2.0 on Retina).
        let scaleFactor: CGFloat
        /// Display bounds in global *point* coordinates (CGEvent space).
        let bounds: CGRect
        var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures the display containing the mouse (or the main display).
    /// Excludes Navi's own windows so the panel never appears in frames, and every window of
    /// `excludingBundleIDs` (screen memory's never-capture apps — privacy workstream).
    static func captureMainDisplay(excludeSelf: Bool = true, excludingBundleIDs: Set<String> = []) async throws -> Frame {
        guard hasPermission else { throw NaviError.permissionDenied("Screen Recording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NaviError.other("No display available for capture")
        }
        var hidden = excludingBundleIDs
        if excludeSelf, let me = Bundle.main.bundleIdentifier { hidden.insert(me) }
        let selfWindows = content.windows.filter { hidden.contains($0.owningApplication?.bundleIdentifier ?? "") }
        let filter = SCContentFilter(display: display, excludingWindows: selfWindows)
        let config = SCStreamConfiguration()
        let scale = screen?.backingScaleFactor ?? 2.0
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bounds = CGDisplayBounds(display.displayID)
        return Frame(image: image, display: display, scaleFactor: scale, bounds: bounds)
    }

    /// Captures one window by its window-server number, whether or not it is
    /// frontmost, covered by other windows, or on another Space. The frame's
    /// `bounds` is the window's frame in global points, so a `ScreenMap`
    /// built from it maps screenshot pixels straight to screen points.
    /// Used by the agent in background mode so it sees the app it drives, not
    /// whatever the user is looking at.
    static func captureWindow(id windowID: CGWindowID) async throws -> Frame {
        guard hasPermission else { throw NaviError.permissionDenied("Screen Recording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NaviError.other("The window Navi was working in is gone")
        }
        let bounds = window.frame
        let screen = NSScreen.screens.first { s in
            // NSScreen frames are bottom-left origin; compare through CG display bounds instead.
            guard let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayBounds(n).intersects(bounds)
        } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2.0
        let display = content.displays.first { CGDisplayBounds($0.displayID).intersects(bounds) } ?? content.displays.first
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(bounds.width * scale))
        config.height = max(1, Int(bounds.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let display else { throw NaviError.other("No display available for capture") }
        return Frame(image: image, display: display, scaleFactor: scale, bounds: bounds)
    }

    /// Downscale so the long edge ≤ `maxLongEdge` pixels. Returns the new image
    /// and the factor applied (multiply model coordinates by 1/factor to get pixels).
    static func downscale(_ image: CGImage, maxLongEdge: Int) -> (CGImage, CGFloat) {
        let long = max(image.width, image.height)
        guard long > maxLongEdge else { return (image, 1) }
        let f = CGFloat(maxLongEdge) / CGFloat(long)
        let w = Int(CGFloat(image.width) * f), h = Int(CGFloat(image.height) * f)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (image, 1) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx.makeImage() ?? image, f)
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.7) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Crops a pixel-space rect (useful for the `zoom` computer-use action).
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        image.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }
}

/// The app the user is looking at: the frontmost app — unless that is Navi itself. A `navi://` link
/// (Shortcuts, Raycast, the CLI, the task bench), the Settings window or a notification click
/// activates Navi, and every "what is in front" question then answered "Navi": the planner never saw
/// the open tab, so "add 2 of these to my cart" on an Amazon product went to the last run's toilet
/// paper and "reload this page" with Safari in front Googled the sentence in Chrome (bench
/// 2026-11-01: not one ⌘Space-typed run started on the tab in front). Then it is the app that was
/// active before Navi (an activation observer), else the owner of the topmost normal window.
enum UserFront {
    nonisolated(unsafe) private static var lastOther: NSRunningApplication?
    private static let selfPID = ProcessInfo.processInfo.processIdentifier

    /// Starts remembering the last app that was active before Navi. Idempotent; called at launch
    /// (and on first use, so a missed launch hook only costs the window-list fallback).
    static func install() { _ = observer }

    private static let observer: NSObjectProtocol = {
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != selfPID { lastOther = f }
        return NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                 object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != selfPID, app.activationPolicy == .regular else { return }
            lastOther = app
        }
    }()

    /// The app the user is looking at (never Navi while another app is running).
    @MainActor
    static func app() -> NSRunningApplication? {
        install()
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != selfPID { return front }
        if let l = lastOther, !l.isTerminated { return l }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let pid = topWindowOwner(list, excluding: selfPID), let a = NSRunningApplication(processIdentifier: pid) { return a }
        return front
    }

    /// The owner of the frontmost normal-layer, visible, window-sized window that is not `excluding`'s.
    /// `windows` is `CGWindowListCopyWindowInfo` output (front to back). Pure: testable.
    static func topWindowOwner(_ windows: [[String: Any]], excluding pid: pid_t) -> pid_t? {
        for w in windows {
            guard let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? (w[kCGWindowOwnerPID as String] as? pid_t),
                  owner != pid else { continue }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? (w[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { continue }
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { bounds = r }
            guard bounds.width >= 80, bounds.height >= 60 else { continue }
            return owner
        }
        return nil
    }
}

/// Frontmost app / window / URL probe shared by memory + agent.
enum FrontmostProbe {
    struct Info: Sendable {
        var bundleID: String?
        var appName: String?
        var windowTitle: String?
        var url: String?
    }

    @MainActor
    /// `userFront`: the app the user is looking at (`UserFront`) — never Navi when a navi:// link or its own
    /// window activated it. Screen memory passes false: a frame with Navi in front is not captured at all.
    static func current(includeURL: Bool = true, userFront: Bool = true) -> Info {
        let app = userFront ? UserFront.app() : NSWorkspace.shared.frontmostApplication
        var info = Info(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        if let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success, let win {
                var t: CFTypeRef?
                if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                    info.windowTitle = t as? String
                }
            }
        }
        if includeURL, let bid = info.bundleID {
            info.url = browserURL(bundleID: bid)
        }
        return info
    }

    /// Active tab URL for common browsers via Apple Events (needs Automation permission).
    static func browserURL(bundleID: String) -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? "Safari"
            script = "tell application \"\(name)\" to return URL of current tab of front window"
        case _ where AXSnapshotter.chromiumBundles.contains(bundleID):
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? "Google Chrome"
            script = "tell application \"\(name)\" to return URL of active tab of front window"
        default: script = nil
        }
        if let script, let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            let result = apple.executeAndReturnError(&err)
            if err == nil, let u = result.stringValue, !u.isEmpty { return u }
        }
        // Firefox, Orion, Zen… have no scripting dictionary: the page's AXWebArea carries its URL.
        return axWebAreaURL(bundleID: bundleID)
    }

    /// The URL of the front window's web area via Accessibility (any browser).
    static func axWebAreaURL(bundleID: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let window = AXSnapshotter.attr(ax, kAXFocusedWindowAttribute) as! AXUIElement? ?? (AXSnapshotter.attr(ax, kAXMainWindowAttribute) as! AXUIElement?) else { return nil }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (el, depth) = stack.popLast(), visited < 250 {
            visited += 1
            if let role = AXSnapshotter.attr(el, kAXRoleAttribute) as? String, role == "AXWebArea" {
                if let u = AXSnapshotter.attr(el, "AXURL") as? URL { return u.absoluteString }
                if let u = AXSnapshotter.attr(el, "AXURL") as? String { return u }
                if let doc = AXSnapshotter.attr(el, kAXDocumentAttribute) as? String { return doc }
            }
            guard depth < 10, let children = AXSnapshotter.elements(AXSnapshotter.attr(el, kAXChildrenAttribute)) else { continue }
            for c in children.prefix(40) { stack.append((c, depth + 1)) }
        }
        return nil
    }
}
