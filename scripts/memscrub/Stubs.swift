import Foundation
import os

// Stand-ins for app-only types so the memory files compile on their own.
enum Log { static let memory = Logger(subsystem: "memscrub", category: "memory") }

struct DigestResult: Sendable, Equatable {
    var title: String
    var summary: String
    var topics: [String]
    var entities: [EntityRef]
    var keyFacts: [String]
    var links: [String]
}

enum FrameCapture { static let browserBundleIDs: Set<String> = [] }

/// FrameTriage's Jev path is never used here (the cleanup only calls the local guard).
final class JevClient: @unchecked Sendable {
    enum JSONValue { case opaque; init(any: Any) { self = .opaque } }
    enum Question {
        case choice(instructions: String, criteria: [String: String])
        case score(instructions: String, criteria: [String])
        case noul(instructions: String)
        case noulJSON(instructions: JSONValue)
    }
    struct Answer { var choice: String?; var noul: Double?; var score: Double? }
    var isConfigured: Bool { false }
    func ask(state: String, questions: [String: Question], cacheable: Bool) async throws -> [String: Answer] { [:] }
}
