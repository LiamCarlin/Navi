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

    @Test func harnessHomeFollowsBrowserHarnessPaths() {
        #expect(ChromeDebugApproval.harnessHome(env: [:]).path == NSHomeDirectory() + "/.config/browser-harness")
        #expect(ChromeDebugApproval.harnessHome(env: ["BH_HOME": "/x/bh"]).path == "/x/bh")
        #expect(ChromeDebugApproval.harnessHome(env: ["XDG_CONFIG_HOME": "/cfg"]).path == "/cfg/browser-harness")
    }

    @Test func everyDaemonLogPairsWithItsPidFile() {
        let home = URL(fileURLWithPath: "/h")
        let files = ChromeDebugApproval.daemonFiles(home: home, logNames: ["bu-navi.log", "bu-default.log", "notes.txt", "shot.png"])
        #expect(files.map(\.log.path) == ["/h/tmp/bu-default.log", "/h/tmp/bu-navi.log"])
        #expect(files.map(\.pid.path) == ["/h/runtime/bu-default.pid", "/h/runtime/bu-navi.pid"])
    }
}
