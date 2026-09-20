import Testing
import Foundation
import CoreGraphics
@testable import Navi

/// Background mode: the agent addresses one app's window instead of the
/// frontmost app + whole display. These cover the pure pieces — matching the
/// AX window to a window-server window, and window-relative coordinate maps.
struct BackgroundAgentTests {
    typealias W = AgentTarget.WindowInfo

    private func w(_ id: CGWindowID, _ title: String, _ r: CGRect, layer: Int = 0, onScreen: Bool = true) -> W {
        W(id: id, pid: 42, title: title, bounds: r, layer: layer, isOnScreen: onScreen)
    }

    // MARK: Window matching

    @Test func matchesByGeometryFirst() {
        let a = w(1, "Inbox", CGRect(x: 0, y: 25, width: 1200, height: 800))
        let b = w(2, "Inbox", CGRect(x: 300, y: 200, width: 600, height: 400))
        // AX frames and CG bounds agree to within a point or two.
        let m = AgentTarget.matchWindow([a, b], frame: CGRect(x: 301, y: 201, width: 600, height: 399), title: "Inbox")
        #expect(m?.id == 2)
    }

    @Test func fallsBackToTitleWhenGeometryIsOff() {
        let a = w(1, "Inbox", CGRect(x: 0, y: 25, width: 1200, height: 800))
        let b = w(2, "Compose", CGRect(x: 300, y: 200, width: 600, height: 400))
        // Frame far from either window (e.g. stale AX frame after a move).
        let m = AgentTarget.matchWindow([a, b], frame: CGRect(x: 900, y: 900, width: 100, height: 100), title: "Compose")
        #expect(m?.id == 2)
    }

    @Test func ignoresNonNormalLayersAndPrefersOnScreen() {
        let shadow = w(9, "", CGRect(x: 0, y: 0, width: 1200, height: 800), layer: 20)   // menu/tooltip layer
        let off = w(1, "Doc", CGRect(x: 0, y: 25, width: 800, height: 600), onScreen: false)
        let on = w(2, "Doc", CGRect(x: 100, y: 125, width: 800, height: 600), onScreen: true)
        let m = AgentTarget.matchWindow([shadow, off, on], frame: nil, title: nil)
        #expect(m?.id == 2)
        #expect(AgentTarget.matchWindow([shadow], frame: nil, title: nil) == nil)
    }

    @Test func emptyCandidatesMatchNothing() {
        #expect(AgentTarget.matchWindow([], frame: CGRect(x: 0, y: 0, width: 10, height: 10), title: "x") == nil)
    }

    // MARK: Window-relative screenshot mapping

    @Test func windowCaptureMapsBackToScreenPoints() {
        // A 900×600 pt window at (300, 200), Retina, captured at 1800×1200 px and
        // downscaled to 1280 px long edge (factor 1280/1800).
        let f = 1280.0 / 1800.0
        let m = ScreenMap(bounds: CGRect(x: 300, y: 200, width: 900, height: 600),
                          scaleFactor: 2.0, downscale: f,
                          imageSize: CGSize(width: 1280, height: 1200 * f))
        // Centre of the screenshot → centre of the window on screen.
        let p = m.point(fromScreenshot: 640, 600 * f)
        #expect(abs(p.x - 750) < 1e-6)
        #expect(abs(p.y - 500) < 1e-6)
        // Never outside the window: a coordinate past the edge clamps to it.
        let edge = m.point(fromScreenshot: 5000, 5000)
        #expect(edge.x == m.bounds.maxX - 1 && edge.y == m.bounds.maxY - 1)
    }

    // MARK: Menu shortcuts vs view-handled keys

    /// ⌘-shortcuts go through the app's menu, which an inactive app never
    /// consults; navigation combos are handled by the focused view and are fine.
    @Test func menuEquivalentsNeedActivationButNavigationDoesNot() throws {
        #expect(try KeyCombo.parse("cmd+s").isMenuEquivalent)
        #expect(try KeyCombo.parse("cmd+shift+t").isMenuEquivalent)
        #expect(try KeyCombo.parse("cmd+l").isMenuEquivalent)
        #expect(try KeyCombo.parse("cmd+a").isMenuEquivalent)
        #expect(!(try KeyCombo.parse("cmd+left").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("cmd+shift+Right").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("cmd+BackSpace").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("shift+left").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("Return").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("ctrl+a").isMenuEquivalent))
        #expect(!(try KeyCombo.parse("cmd").isMenuEquivalent))   // bare modifier (hold_key)
    }

    // MARK: Input route

    @Test func processRouteIsBackground() {
        #expect(InputController.Route.process(pid: 1, window: nil).isBackground)
        #expect(!InputController.Route.hid.isBackground)
        #expect(InputController.Route.process(pid: 1, window: 7) == .process(pid: 1, window: 7))
    }
}
