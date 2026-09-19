import Testing
import Foundation
@testable import Navi

struct SystemCommandsTests {
    @Test func exactMatches() {
        #expect(SystemCommands.matches("sleep").first?.action == .sleep)
        #expect(SystemCommands.matches("lock screen").first?.action == .lock)
        #expect(SystemCommands.matches("toggle dark mode").first?.action == .darkMode(nil))
        #expect(SystemCommands.matches("empty trash").first?.action == .emptyTrash)
        #expect(SystemCommands.matches("wifi off").first?.action == .wifi(false))
    }
    @Test func destructiveNeedsNow() {
        #expect(SystemCommands.matches("shut down").first?.action == .confirmRequired("shut down"))
        #expect(SystemCommands.matches("shut down now").first?.action == .shutDown)
        #expect(SystemCommands.matches("restart now").first?.action == .restart)
    }
    @Test func volumeAndQuit() {
        #expect(SystemCommands.matches("volume 50").first?.action == .volume(50))
        #expect(SystemCommands.matches("quit slack").first?.action == .quitApp("slack", force: false))
        #expect(SystemCommands.matches("kill chrome").first?.action == .quitApp("chrome", force: true))
    }
    @Test func prefixesRankLower() {
        let m = SystemCommands.matches("wifi")
        #expect(m.count == 2 && m.allSatisfy { $0.score < 1.0 })
        #expect(SystemCommands.matches("maps").isEmpty)
    }
}
