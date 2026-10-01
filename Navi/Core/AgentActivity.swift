import Foundation

/// Whether a computer-use run is driving the screen right now. Screen memory skips its
/// capture while one is (`CaptureScheduler`): the frames would show Navi's own clicks, not
/// the user's work — and teach `UserHabits` the agent's habits — and the capture's OCR, Jev
/// triage and browser-URL AppleScript compete with the run for the Neural Engine, the Jev
/// connection and Chrome at exactly the moment latency matters most.
enum AgentActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running = 0

    static var isBusy: Bool { lock.withLock { running > 0 } }

    /// Marks a run as started; call the returned closure when it ends (extra calls do nothing).
    static func begin() -> @Sendable () -> Void {
        lock.withLock { running += 1 }
        let token = Token()
        return { if token.end() { lock.withLock { running = max(0, running - 1) } } }
    }

    private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        /// True the first time only.
        func end() -> Bool { lock.withLock { defer { ended = true }; return !ended } }
    }
}
