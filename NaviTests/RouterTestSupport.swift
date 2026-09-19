import Foundation
@testable import Navi

/// Shared fakes for Router tests. Nothing here touches the network or the filesystem.
enum RouterFakes {
    static let apps: [AppEntry] = [
        AppEntry(name: "Maps", path: "/System/Applications/Maps.app", bundleID: "com.apple.Maps"),
        AppEntry(name: "Mail", path: "/System/Applications/Mail.app", bundleID: "com.apple.mail"),
        AppEntry(name: "Messages", path: "/System/Applications/Messages.app", bundleID: "com.apple.MobileSMS"),
        AppEntry(name: "Google Chrome", path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome"),
        AppEntry(name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app", bundleID: "com.microsoft.VSCode"),
        AppEntry(name: "System Settings", path: "/System/Applications/System Settings.app", bundleID: "com.apple.systempreferences"),
        AppEntry(name: "Calculator", path: "/System/Applications/Calculator.app", bundleID: "com.apple.calculator"),
        AppEntry(name: "Slack", path: "/Applications/Slack.app", bundleID: "com.tinyspeck.slackmacgap"),
        AppEntry(name: "Safari", path: "/Applications/Safari.app", bundleID: "com.apple.Safari"),
        AppEntry(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
        AppEntry(name: "Xcode", path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode"),
        AppEntry(name: "Finder", path: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder"),
        AppEntry(name: "Magnet", path: "/Applications/Magnet.app", bundleID: "com.crowdcafe.windowmagnet"),
    ]

    static func appIndex() -> AppIndex { AppIndex(entries: apps) }

    final class Memory: MemoryServicing, @unchecked Sendable {
        var hits: [MemoryHit] = []
        @MainActor var status = MemoryStatus()
        @MainActor func start() {}
        @MainActor func stop() {}
        func search(query: String, limit: Int) async -> [MemoryHit] { Array(hits.prefix(limit)) }
        func digestNow() async {}
    }

    final class Agent: ComputerAgentRunning, @unchecked Sendable {
        @MainActor func run(task: String, context: QueryContext) -> AgentRunHandle {
            AgentRunHandle(task: task, cancel: {}, respond: { _ in })
        }
    }

    static func router(memory: Memory = Memory()) -> QueryRouter {
        QueryRouter(jev: JevClient(), claude: ClaudeClient(), memory: memory, agent: Agent(), appIndex: appIndex())
    }
}
