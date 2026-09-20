import Foundation
import os

/// Unified logging. View with:  log stream --predicate 'subsystem == "com.liamcarlin.navi"' --level debug
enum Log {
    static let subsystem = "com.liamcarlin.navi"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let router = Logger(subsystem: subsystem, category: "router")
    static let jev = Logger(subsystem: subsystem, category: "jev")
    static let claude = Logger(subsystem: subsystem, category: "claude")
    static let agent = Logger(subsystem: subsystem, category: "agent")
    static let memory = Logger(subsystem: subsystem, category: "memory")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}

#if DEBUG
/// Debug-only file trace (`~/Library/Logs/Navi/debug.log`) for when `log stream`
/// isn't practical. Never compiled into Release.
enum DebugTrace {
    private static let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Navi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    private static let queue = DispatchQueue(label: "navi.debugtrace")
    static func log(_ message: @autoclosure () -> String) {
        let line = "\(Date()) \(message())\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8)) }
        }
    }
}
#endif
