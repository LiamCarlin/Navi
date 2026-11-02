import AppKit
import Testing
@testable import Navi

@Suite struct NaviCursorTests {
    private func window(_ id: Int, pid: Int32, _ frame: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: frame.dictionaryRepresentation]
    }

    @Test func sitsOnTheTargetAppsWindowEvenWhenAnotherIsInFront() {
        let list = [window(1, pid: 50, CGRect(x: 0, y: 0, width: 400, height: 30), layer: 25),   // menu bar extra
                    window(2, pid: 10, CGRect(x: 0, y: 0, width: 800, height: 600)),             // the user's window
                    window(3, pid: 20, CGRect(x: 100, y: 100, width: 800, height: 600))]         // the driven app
        let p = CGPoint(x: 200, y: 200)
        #expect(NaviCursor.windowID(at: p, pids: [20], in: list, excluding: 99) == 3)
        #expect(NaviCursor.windowID(at: p, pids: nil, in: list, excluding: 99) == 2)
        #expect(NaviCursor.windowID(at: CGPoint(x: 10, y: 10), pids: nil, in: list, excluding: 99) == 2)   // never a menu-bar layer
        #expect(NaviCursor.windowID(at: CGPoint(x: 950, y: 50), pids: [20], in: list, excluding: 99) == nil)
    }

    @Test func neverItsOwnWindow() {
        let list = [window(7, pid: 99, CGRect(x: 0, y: 0, width: 500, height: 500)),
                    window(8, pid: 10, CGRect(x: 0, y: 0, width: 500, height: 500))]
        #expect(NaviCursor.windowID(at: CGPoint(x: 5, y: 5), pids: nil, in: list, excluding: 99) == 8)
    }

    @Test func tipLandsOnThePoint() {
        // Global (top-left origin) 300,100 on a 1000-pt-tall main screen is Cocoa y 900.
        let f = NaviCursor.panelFrame(tip: CGPoint(x: 300, y: 100), primaryHeight: 1000)
        #expect(f.size == CGSize(width: NaviCursor.panelSize, height: NaviCursor.panelSize))
        #expect(f.minX + NaviCursor.tipInset == 300)
        #expect(f.maxY - NaviCursor.tipInset == 900)
    }

    @Test func offInTheTestHost() {
        #expect(!NaviCursor.isEnabled)
    }
}
