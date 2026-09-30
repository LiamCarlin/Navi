import CoreGraphics
import Foundation

/// `~/Library/Logs/Navi/runs/<timestamp>/`, upstream's run folder (docs/run-folder.md):
/// everything a stall needs to be understood — and re-decided offline — without the screen.
///
///     run.json                  goal, outcome, answer, calls, history, hand-offs
///     step-NNN-payload.json     the exact state and every question sent to Jev
///     step-NNN-answers.json     every probability returned, the decision, the stop counters
///     step-NNN-review.json      the writer's answer when Jev stopped
///     step-NNN.png              the capture the writer read (when screen recording is allowed)
///
/// Local only, never uploaded; the newest `keep` runs are kept. Typed text is in the payloads
/// exactly as the writer wrote it — the folder lives next to the other agent logs for that reason.
final class CURunFolder: @unchecked Sendable {
    static let keep = 30
    let url: URL
    private let queue = DispatchQueue(label: "navi.cu.runfolder", qos: .utility)

    init(goal: String) {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Navi/runs")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS"
        url = root.appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Self.prune(root)
        write("goal.txt", text: goal)
    }

    static func prune(_ root: URL) {
        let fm = FileManager.default
        guard let runs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for old in runs.map(\.lastPathComponent).sorted().dropLast(keep) { try? fm.removeItem(at: root.appendingPathComponent(old)) }
    }

    static func name(_ step: Int, _ suffix: String) -> String { String(format: "step-%03d-%@", step, suffix) }

    func write(_ file: String, json: Any) {
        queue.async { [url] in
            let clean = Self.jsonSafe(json)
            guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: url.appendingPathComponent(file))
        }
    }

    func write(_ file: String, text: String) {
        queue.async { [url] in try? Data(text.utf8).write(to: url.appendingPathComponent(file)) }
    }

    func write(_ file: String, data: Data) {
        queue.async { [url] in try? data.write(to: url.appendingPathComponent(file)) }
    }

    /// Questions as they go over the wire.
    static func questionsJSON(_ q: [String: JevClient.Question]) -> Any {
        guard let data = try? JSONEncoder().encode(q), let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return obj
    }

    /// Anything JSONSerialization would reject (CGFloat, CGRect, nested optionals) as something it takes.
    static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case let r as CGRect: return [r.minX, r.minY, r.width, r.height].map { Double($0) }
        case let f as CGFloat: return Double(f)
        case is String, is NSNumber, is NSNull, is Int, is Double, is Bool: return v
        default: return String(describing: v)
        }
    }
}
