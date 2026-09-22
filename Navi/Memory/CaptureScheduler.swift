import AppKit
import Foundation

/// Snapshot of the memory-related settings, taken on the main actor once per tick.
struct CaptureConfig: Sendable, Equatable {
    var enabled: Bool
    var paused: Bool
    var intervalSeconds: Int
    var excludedBundleIDs: Set<String>
    var keepScreenshots: Bool

    @MainActor static var current: CaptureConfig {
        let s = NaviSettings.shared
        return CaptureConfig(enabled: s.memoryCaptureEnabled,
                             paused: s.memoryIsPaused,
                             intervalSeconds: max(5, s.memoryCaptureIntervalSeconds),
                             excludedBundleIDs: Set(s.memoryExcludedBundleIDs),
                             keepScreenshots: s.memoryKeepScreenshots)
    }
}

/// Periodic capture loop: screenshot → dHash dedupe → OCR → Jev triage → store.
/// Runs as a single utility-priority task; ticks never overlap.
final class CaptureScheduler: @unchecked Sendable {
    typealias StatusUpdate = @Sendable (@escaping @Sendable (inout MemoryStatus) -> Void) -> Void

    let store: MemoryStore
    let jev: JevClient
    private let updateStatus: StatusUpdate

    private var task: Task<Void, Never>?
    private var previous: (bundleID: String, title: String?, hash: UInt64)?
    private var capturedWhileIdle = false
    private var permissionPrompted = false
    private var permissionErrorShown = false
    private var automationAsked: Set<String> = []
    private let lock = NSLock()

    static let idleThreshold: TimeInterval = 5 * 60
    static let hashDistanceThreshold = 6

    enum Skip: Equatable, Sendable {
        case disabled, paused, screenLocked, screensaver, displayAsleep, noPermission
        case excludedApp(String), idle, unchanged, noFrontmostApp
    }

    init(store: MemoryStore, jev: JevClient, updateStatus: @escaping StatusUpdate) {
        self.store = store
        self.jev = jev
        self.updateStatus = updateStatus
        if let last = try? store.latestFrame() {
            previous = (last.bundleID, last.windowTitle, last.phash)
        }
    }

    var isRunning: Bool { lock.withLock { task != nil } }

    func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [weak self] in
                await self?.loop()
            }
        }
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    private func loop() async {
        Log.memory.info("Capture loop started")
        // First tick shortly after start so the user sees something happen.
        try? await Task.sleep(for: .seconds(3))
        var lastSkip: Skip?
        while !Task.isCancelled {
            let cfg = await MainActor.run { CaptureConfig.current }
            let started = Date()
            let skip = await tick(cfg)
            // Log a skip reason once when it changes (not every tick).
            if skip != lastSkip {
                if let skip { Log.memory.info("Capture skipped: \(String(describing: skip), privacy: .public)") }
                else { Log.memory.info("Capture resumed") }
                lastSkip = skip
            }
            let elapsed = Date().timeIntervalSince(started)
            let wait = max(2, Double(cfg.intervalSeconds) - elapsed)
            try? await Task.sleep(for: .seconds(wait))
        }
        Log.memory.info("Capture loop stopped")
    }

    /// One capture attempt. Returns the reason it was skipped, or nil when a
    /// frame was stored. Never throws: errors land in `status.lastError`.
    @discardableResult
    func tick(_ cfg: CaptureConfig, now: Date = Date()) async -> Skip? {
        guard cfg.enabled else { return .disabled }
        guard !cfg.paused else { return .paused }
        if FrameCapture.isScreenLocked { return .screenLocked }
        if FrameCapture.isDisplayAsleep { return .displayAsleep }
        if FrameCapture.isScreensaverRunning { return .screensaver }

        guard ScreenCapture.hasPermission else {
            let prompted = lock.withLock { () -> Bool in
                let p = permissionPrompted; permissionPrompted = true; return p
            }
            if !prompted {
                // Shows the system prompt once; user grants in System Settings.
                ScreenCapture.requestPermission()
            }
            let shown = lock.withLock { () -> Bool in
                let s = permissionErrorShown; permissionErrorShown = true; return s
            }
            if !shown {
                Log.memory.warning("Screen Recording permission missing; capture idle")
                updateStatus { $0.lastError = "Screen Recording permission needed — grant Navi in System Settings → Privacy & Security → Screen Recording, then relaunch Navi." }
            }
            return .noPermission
        }

        // Idle: capture once after the user goes quiet, then back off until they return.
        let idle = FrameCapture.secondsSinceUserInput
        if idle > Self.idleThreshold {
            let already = lock.withLock { () -> Bool in
                let a = capturedWhileIdle; capturedWhileIdle = true; return a
            }
            if already { return .idle }
        } else {
            lock.withLock { capturedWhileIdle = false }
        }

        let front = await MainActor.run { FrontmostProbe.current(includeURL: false) }
        guard let bundleID = front.bundleID, bundleID != Bundle.main.bundleIdentifier else { return .noFrontmostApp }
        if cfg.excludedBundleIDs.contains(bundleID) { return .excludedApp(bundleID) }
        let url = await browserURL(bundleID: bundleID)

        do {
            let frame = try await ScreenCapture.captureMainDisplay()
            let hash = FrameCapture.dHash(frame.image)
            let prev = lock.withLock { previous }
            if let prev, prev.bundleID == bundleID, prev.title == front.windowTitle,
               FrameCapture.hamming(prev.hash, hash) < Self.hashDistanceThreshold {
                return .unchanged
            }

            let t0 = Date()
            let ocr = try await FrameCapture.recognizeText(in: frame.image)
            let ocrMs = Int(Date().timeIntervalSince(t0) * 1000)

            let input = FrameTriage.Input(bundleID: bundleID, appName: front.appName ?? bundleID,
                                          windowTitle: front.windowTitle, url: url, timestamp: now,
                                          ocrText: ocr, previousApp: prev?.bundleID, previousTitle: prev?.title)
            // One cloud run per frame (`X-Navi-Run`), metered under `recall_triage`.
            let triage = await CloudRun.$current.withValue(CloudRun(feature: .recallTriage)) {
                await FrameTriage.triage(input, jev: jev)
            }

            var record = FrameRecord(timestamp: now, bundleID: bundleID, appName: front.appName ?? bundleID,
                                     windowTitle: front.windowTitle, url: url, ocrText: "",
                                     phash: hash, activity: triage.activity, importance: triage.importance,
                                     isNewContext: triage.isNewContext)
            if triage.isSensitive {
                // Stub row only: app + time. No text, no title, no URL, no thumbnail.
                record.windowTitle = nil
                record.url = nil
                record.importance = 0
                Log.memory.info("Sensitive frame in \(record.appName, privacy: .public); stored stub only")
            } else {
                record.ocrText = ocr
                if cfg.keepScreenshots, let jpeg = FrameCapture.thumbnailJPEG(frame.image) {
                    let dest = FrameCapture.thumbnailURL(in: store.framesDirectory, at: now)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try jpeg.write(to: dest, options: .atomic)
                    record.thumbPath = dest.path
                }
            }
            let id = try store.insertFrame(record)
            lock.withLock { previous = (bundleID, front.windowTitle, hash) }
            let today = (try? store.framesToday()) ?? 0
            Log.memory.debug("Frame #\(id) \(record.appName, privacy: .public) act=\(triage.activity, privacy: .public) imp=\(triage.importance) new=\(triage.isNewContext) via=\(triage.source.rawValue, privacy: .public) ocr=\(ocr.count)ch/\(ocrMs)ms")
            updateStatus { s in
                s.lastCaptureAt = now
                s.framesToday = today
                if s.lastError?.hasPrefix("Screen Recording") == true || s.lastError?.hasPrefix("Capture failed") == true { s.lastError = nil }
            }
            return nil
        } catch {
            Log.memory.error("Capture failed: \(error.localizedDescription)")
            updateStatus { $0.lastError = "Capture failed: \(error.localizedDescription)" }
            return nil
        }
    }

    /// Front tab URL for browsers, only once Automation consent exists. The
    /// consent prompt is triggered once per browser from a background thread
    /// so the main thread is never blocked on the dialog.
    private func browserURL(bundleID: String) async -> String? {
        guard FrameCapture.browserBundleIDs.contains(bundleID) else { return nil }
        if FrameCapture.automationPermitted(bundleID: bundleID, ask: false) {
            return await MainActor.run { FrontmostProbe.browserURL(bundleID: bundleID) }
        }
        let asked = lock.withLock { () -> Bool in
            let a = automationAsked.contains(bundleID); automationAsked.insert(bundleID); return a
        }
        if !asked {
            Task.detached(priority: .utility) {
                _ = FrameCapture.automationPermitted(bundleID: bundleID, ask: true)
            }
        }
        return nil
    }
}
