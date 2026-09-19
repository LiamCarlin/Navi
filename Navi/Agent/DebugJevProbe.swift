#if DEBUG
import Foundation

/// `navi://debug-jev-probe?out=/tmp/x.json` — runs one JevDriver decision on a
/// synthetic Finder-like snapshot against the live API and writes the verdict.
/// Validates the exact request the native driver sends, without Accessibility.
enum DebugJevProbe {
    static func handle(_ url: URL, jev: JevClient) -> Bool {
        guard url.host == "debug-jev-probe" else { return false }
        let out = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "out" }?.value ?? "/tmp/navi-jev-probe.json"
        let els: [AXElement] = [
            AXElement(id: "e1", role: "AXTextField", subrole: "AXSearchField", label: "Search", value: "", frame: CGRect(x: 900, y: 60, width: 200, height: 24), isFocused: false, path: "Toolbar", actions: ["AXConfirm"]),
            AXElement(id: "e2", role: "AXButton", label: "Back", value: nil, frame: CGRect(x: 20, y: 60, width: 30, height: 24), path: "Toolbar", actions: ["AXPress"]),
            AXElement(id: "e3", role: "AXRow", label: "Documents", value: nil, frame: CGRect(x: 40, y: 140, width: 200, height: 22), path: "Sidebar", actions: ["AXPress"]),
            AXElement(id: "e4", role: "AXRow", label: "Downloads", value: nil, frame: CGRect(x: 40, y: 162, width: 200, height: 22), path: "Sidebar", actions: ["AXPress"]),
            AXElement(id: "e5", role: "AXRow", label: "budget-2026.xlsx", value: nil, frame: CGRect(x: 300, y: 140, width: 300, height: 22), path: "Files", actions: ["AXPress", "AXOpen"]),
            AXElement(id: "e6", role: "AXRow", label: "notes.md", value: nil, frame: CGRect(x: 300, y: 162, width: 300, height: 22), path: "Files", actions: ["AXPress", "AXOpen"]),
            AXElement(id: "e7", role: "AXMenuBarItem", label: "File", value: nil, frame: CGRect(x: 80, y: 0, width: 40, height: 22), path: "Menu bar", actions: ["AXPress"]),
        ]
        let snap = AXSnapshot(elements: els, windowTitle: "Desktop", url: nil, focused: nil,
                              visibleText: "Favorites Documents Downloads Desktop  budget-2026.xlsx notes.md",
                              pid: 1, bundleID: "com.apple.finder", appName: "Finder")
        let input = JevDriver.StepInput(task: "Open the budget spreadsheet", step: 1, maxSteps: 40, snapshot: snap, history: [])
        Task.detached {
            let driver = JevDriver(jev: jev)
            var result: [String: Any] = [:]
            do {
                let t = Date()
                let (v, req) = try await driver.ask(input)
                let d = JevDriver.decide(v, request: req, threshold: 0.5)
                result = [
                    "ok": true,
                    "wall_ms": Int(Date().timeIntervalSince(t) * 1000),
                    "api_ms": v.latencyMs,
                    "operation": v.operation?.choice ?? "",
                    "operation_confidence": v.operation?.confidence ?? 0,
                    "operation_probabilities": v.operation?.probabilities ?? [:],
                    "targets": v.targets.mapValues { ["choice": $0.choice, "confidence": $0.confidence] },
                    "task_complete": v.taskComplete,
                    "decision": String(describing: d),
                    "offered_operations": req.operations,
                ]
            } catch {
                result = ["ok": false, "error": error.localizedDescription]
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
        }
        return true
    }
}
#endif
