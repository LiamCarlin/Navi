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
