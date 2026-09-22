import AppKit
import Foundation
// usage: axprobe <bundle-id> ["<goal>" ...]   — see build.sh
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: axprobe <bundle-id> [goal ...]"); exit(2) }
let bid = args[1]
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { print("not running: \(bid)"); exit(1) }
let target = AgentTarget(pid: app.processIdentifier, bundleID: bid, appName: app.localizedName)
let sem = DispatchSemaphore(value: 0)
Task {
    let snapper = AXSnapshotter()
    let snap = await snapper.capture(near: nil, includeMenuBar: false, target: target)
    print("app=\(snap.appName ?? "?") title=\(snap.windowTitle ?? "?") url=\(snap.url ?? "-") elements=\(snap.elements.count)")
    if args.count == 2 || ProcessInfo.processInfo.environment["AXPROBE_TABLE"] != nil {
        for e in snap.elements { print("[\(e.index)] \(e.role) “\(e.label.prefix(70))” v=\(e.value.map { String($0.prefix(30)) } ?? "") ops=\(e.operations) \(e.isWebContent ? "web" : "app") path=\(e.path.prefix(50))") }
        print("--- text ---\n\(snap.visibleText.prefix(800))")
    }
    guard args.count > 2 else { sem.signal(); return }
    guard Keychain.has(.typesafe) || Keychain.has(.vercelGateway) else { print("Set TYPESAFE_API_KEY (or AI_GATEWAY_API_KEY) to ask Jev."); sem.signal(); return }
    let jev = JevClient()
    let driver = JevDriver(jev: jev)
    let skill = AppSkills.skill(bundleID: snap.bundleID, url: snap.url)
    print("skill=\(skill?.name ?? "none")")
    for goal in args.dropFirst(2) {
        var input = JevDriver.StepInput(task: goal, step: 1, maxSteps: 20, snapshot: snap, history: [])
        input.playbook = skill.map { AppSkills.playbook(for: $0, goal: goal) }
        input.keyCombos = AppSkills.keyCombos(for: skill)
        input.appCandidates = TextCandidates.extract(task: goal).filter { $0.source == "app" }.map(\.text)
        input.urlCandidates = TextCandidates.extract(task: goal).filter { $0.source == "url" || $0.source == "domain" }.map(\.text)
        do {
            let (v, req) = try await driver.ask(input)
            let d = JevDriver.decide(v, request: req, threshold: 0.5, effectGoal: !AgentRun.isLookup(goal), actionsTaken: 0, typingGoal: JevDriver.goalAsksToType(goal))
            var targetDesc = ""
            if let op = v.operation, let head = JevDriver.Operation(rawValue: op.choice)?.targetHead, let t = v.targets[head] {
                let el = snap.elements.first { "\($0.index)" == t.choice }
                targetDesc = " → [\(t.choice)] \(el.map { "\($0.role) “\($0.label.prefix(50))”" } ?? t.choice) (\(Int(t.confidence * 100))%)"
            }
            let top = (v.operation?.probabilities ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
            print("GOAL “\(goal)”\n  \(JevDriver.statusLine(v))\(targetDesc)\n  ops: \(top) · complete=\(Int(v.taskComplete * 100))% irreversible=\(Int(v.isIrreversible * 100))%\n  decision: \(d)")
        } catch { print("GOAL “\(goal)” error: \(error)") }
    }
    sem.signal()
}
sem.wait()
