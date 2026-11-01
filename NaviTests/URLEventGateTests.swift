import Testing
import Foundation
@testable import Navi

/// `URLEventGate`: navi:// URLs that arrive before launch finishes are queued (the
/// cold-launch crash), and a reopen that comes with a URL does not open the main window.
@Suite struct URLEventGateTests {
    /// A clock the test moves by hand.
    final class Clock {
        var t = Date(timeIntervalSinceReferenceDate: 815_000_000)
        func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) }
    }

    private let run = URL(string: "navi://run?q=open%20maps")!
    private let voice = URL(string: "navi://voice")!

    @Test func urlsBeforeLaunchAreQueuedAndHandedBackInOrder() {
        var gate = URLEventGate()
        #expect(gate.receive([run]).isEmpty)
        #expect(gate.receive([voice]).isEmpty)
        #expect(gate.finishLaunching() == [run, voice])
        #expect(gate.pending.isEmpty)
        #expect(gate.finishLaunching().isEmpty)   // handed back once
    }

    @Test func urlsAfterLaunchAreHandledAtOnce() {
        var gate = URLEventGate()
        #expect(gate.finishLaunching().isEmpty)
        #expect(gate.receive([run]) == [run])
        #expect(gate.pending.isEmpty)
    }

    @Test func plainReopenShowsTheMainWindow() {
        let clock = Clock()
        let gate = URLEventGate(now: { clock.t })
        let reopenedAt = gate.timestamp()
        clock.advance(URLEventGate.reopenDecisionDelay)
        #expect(gate.reopenShowsMainWindow(reopenedAt: reopenedAt))
    }

    @Test func reopenRightAfterAURLShowsNothing() {
        let clock = Clock()
        var gate = URLEventGate(now: { clock.t })
        _ = gate.finishLaunching()
        _ = gate.receive([run])
        clock.advance(0.05)
        let reopenedAt = gate.timestamp()
        clock.advance(URLEventGate.reopenDecisionDelay)
        #expect(!gate.reopenShowsMainWindow(reopenedAt: reopenedAt))
    }

    @Test func reopenRightBeforeAURLShowsNothing() {
        // AppKit may deliver the reopen first; the URL lands during the decision delay.
        let clock = Clock()
        var gate = URLEventGate(now: { clock.t })
        _ = gate.finishLaunching()
        let reopenedAt = gate.timestamp()
        clock.advance(0.05)
        _ = gate.receive([run])
        clock.advance(URLEventGate.reopenDecisionDelay - 0.05)
        #expect(!gate.reopenShowsMainWindow(reopenedAt: reopenedAt))
    }

    @Test func reopenLongAfterAURLShowsTheMainWindow() {
        // A Dock click a few seconds after a link ran is the user asking for Navi.
        let clock = Clock()
        var gate = URLEventGate(now: { clock.t })
        _ = gate.finishLaunching()
        _ = gate.receive([run])
        clock.advance(URLEventGate.window + 0.5)
        let reopenedAt = gate.timestamp()
        clock.advance(URLEventGate.reopenDecisionDelay)
        #expect(gate.reopenShowsMainWindow(reopenedAt: reopenedAt))
    }

    @Test func urlDuringLaunchStillSuppressesItsReopen() {
        let clock = Clock()
        var gate = URLEventGate(now: { clock.t })
        _ = gate.receive([run])            // queued: launch not finished
        clock.advance(0.3)
        let reopenedAt = gate.timestamp()
        _ = gate.finishLaunching()
        clock.advance(URLEventGate.reopenDecisionDelay)
        #expect(!gate.reopenShowsMainWindow(reopenedAt: reopenedAt))
    }
}
