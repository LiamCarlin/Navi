#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit

/// Debug-only URL hook for layout checks without a human at the screen:
///
///     navi://debug-snapshot?section=general&out=/tmp/x.png[&ax=/tmp/x.txt][&onboarding=1][&w=960&h=640]
///
/// Opens the main window at `section`, resizes it, and
///   • writes a PNG of the window via ScreenCaptureKit when Navi has Screen
///     Recording (otherwise a Core Animation render, which omits SwiftUI's
///     display-list content — useful only as a smoke test), and
///   • with `ax=`, writes the AppKit view hierarchy (window-local frames of
///     every hosted control / scroll view) and flags anything outside the
///     window bounds, so clipping can be checked structurally.
///
/// Compiled out of Release builds.
@MainActor
enum DebugSnapshot {
    static func handle(_ url: URL) -> Bool {
        guard url.host == "debug-snapshot" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        let out = q("out") ?? "/tmp/navi-snapshot.png"
        let section = q("section").flatMap(SettingsSection.init(rawValue:))
        let width = Double(q("w") ?? "") ?? 960
        let height = Double(q("h") ?? "") ?? 640
        let onboarding = q("onboarding") == "1"
        let delay = Double(q("delay") ?? "") ?? 1.5
        let axOut = q("ax")

        AppDelegate.shared?.openMainWindow(section: section)
        if onboarding { NotificationCenter.default.post(name: .naviShowOnboarding, object: nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let win = AppActivation.mainWindow else { Log.settings.error("snapshot: no main window"); return }
            var frame = win.frame
            frame.size = NSSize(width: width, height: height)
            win.setFrame(frame, display: true)
            win.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let target: NSWindow = win.attachedSheet ?? win
                if let axOut { dumpHierarchy(window: target, to: axOut) }
                Task { await write(window: target, to: out) }
            }
        }
        return true
    }

    // MARK: PNG

    private static func write(window: NSWindow, to path: String) async {
        var cg: CGImage? = nil
        if ScreenCapture.hasPermission { cg = await captureWithSCK(window: window) }
        if cg == nil { cg = renderLayers(window: window) }
        guard let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            Log.settings.error("snapshot: could not render"); return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            Log.settings.info("snapshot written: \(path)")
        } catch {
            Log.settings.error("snapshot write failed: \(error.localizedDescription)")
        }
    }

    private static func captureWithSCK(window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWin = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWin)
            let cfg = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            cfg.width = Int(scWin.frame.width * scale)
            cfg.height = Int(scWin.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            Log.settings.error("snapshot SCK failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func renderLayers(window: NSWindow) -> CGImage? {
        guard let view = window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: view.bounds.size))
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    // MARK: View hierarchy dump

    private static func dumpHierarchy(window: NSWindow, to path: String) {
        let size = window.frame.size
        var lines = ["window \(Int(size.width))x\(Int(size.height)) title=\"\(window.title)\" class=\(type(of: window)) visible=\(window.isVisible) policy=\(NSApp.activationPolicy().rawValue)",
                     "--- NSView hierarchy (window-local, top-left origin) ---"]
        var clipped = 0, count = 0
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)

        func walk(_ v: NSView, depth: Int) {
            guard depth < 60, count < 8000 else { return }
            count += 1
            let f = v.convert(v.bounds, to: nil)   // window coords, bottom-left origin
            let local = CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            let clip = !v.isHidden && f.width > 0 && f.height > 0 && !bounds.contains(local)
            if clip { clipped += 1 }
            var label = ""
            if let c = v as? NSControl {
                label = (c as? NSButton)?.title ?? c.stringValue
                if let tf = c as? NSTextField, tf.stringValue.isEmpty { label = tf.placeholderString ?? "" }
            }
            let name = "\(type(of: v))"
            if v is NSControl || v is NSScrollView || v is NSTableView || clip {
                lines.append(String(repeating: "  ", count: depth) + "\(name.prefix(40)) [\(Int(local.minX)),\(Int(local.minY)) \(Int(local.width))x\(Int(local.height))]"
                             + (label.isEmpty ? "" : " \"\(label.prefix(60))\"") + (clip ? "   <-- OUTSIDE WINDOW" : "") + (v.isHidden ? " (hidden)" : ""))
            }
            for s in v.subviews { walk(s, depth: depth + 1) }
        }
        if let cv = window.contentView { walk(cv, depth: 0) }
        lines.append("views=\(count) outside_window=\(clipped)  (scroll document views below the fold are expected)")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
