import Foundation

/// What the agent reads from screen memory before a run — the user's things and people
/// (`UserKnowledge`), their routines (`UserRoutines`) and paths (`UserPaths`) — as one value.
///
/// Live runs use the installed instances (`ScreenMemory.live`, nil when memory is off or under
/// unit tests). The task bench and probes pass their own, built on a *copy* of memory.sqlite
/// (`ScreenMemory(store:)`), to the same entry points (`TaskGrounding.ground(task:memory:jev:)`,
/// `UserRoutines.match(task:memory:jev:)`), so they test the code the app runs, not a copy of it.
struct ScreenMemory: @unchecked Sendable {
    var knowledge: UserKnowledge
    var routines: UserRoutines?
    var paths: UserPaths?

    /// The installed instances (nil without screen memory or under tests).
    static var live: ScreenMemory? {
        guard let k = UserKnowledge.current else { return nil }
        return ScreenMemory(knowledge: k, routines: UserRoutines.current, paths: UserPaths.current)
    }

    /// Fresh instances on `store` (a copy of memory.sqlite), the path graph built now.
    init(store: MemoryStore, now: Date = Date()) {
        knowledge = UserKnowledge(store: store)
        routines = UserRoutines(store: store)
        let p = UserPaths(store: store)
        p.rebuild(now: now)
        paths = p
    }

    init(knowledge: UserKnowledge, routines: UserRoutines?, paths: UserPaths?) {
        self.knowledge = knowledge
        self.routines = routines
        self.paths = paths
    }

    /// The app the person the task names is reached in (`UserKnowledge.channelApp`).
    func channelApp(for task: String) -> String? {
        UserKnowledge.channelApp(task: task, matches: knowledge.matches(for: task))
    }
}
