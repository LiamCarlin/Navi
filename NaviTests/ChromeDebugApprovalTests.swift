import Foundation
import Testing
@testable import Navi

struct ChromeDebugApprovalTests {
    @Test func waitsOnlyWhileTheLastLineIsHandshakeWait() {
        let parked = "connecting to ws://127.0.0.1:9222\nhandshake-wait: if Chrome shows an 'Allow remote debugging?' popup, click Allow\n"
        #expect(ChromeDebugApproval.isAwaitingApproval(logTail: parked))
        let attached = parked + "attached F209 (https://example.com) session=05A4\nlistening on /tmp/bu.sock (name=default, remote=local)\n"
        #expect(!ChromeDebugApproval.isAwaitingApproval(logTail: attached))
        #expect(!ChromeDebugApproval.isAwaitingApproval(logTail: ""))
        #expect(!ChromeDebugApproval.isAwaitingApproval(logTail: "connecting to ws://127.0.0.1:9222"))
    }

    @Test func harnessFilesFollowBrowserHarnessPaths() {
        let home = NSHomeDirectory()
        let plain = ChromeDebugApproval.harnessFiles(env: [:])
        #expect(plain.log.path == home + "/.config/browser-harness/tmp/bu-default.log")
        #expect(plain.pid.path == home + "/.config/browser-harness/runtime/bu-default.pid")

        let named = ChromeDebugApproval.harnessFiles(env: ["BH_HOME": "/x/bh", "BU_NAME": "navi"])
        #expect(named.log.path == "/x/bh/tmp/bu-navi.log")
        #expect(named.pid.path == "/x/bh/runtime/bu-navi.pid")

        let isolated = ChromeDebugApproval.harnessFiles(env: ["BH_TMP_DIR": "/t"])
        #expect(isolated.log.path == "/t/bu.log")
        #expect(isolated.pid.path == "/t/bu.pid")
    }
}
