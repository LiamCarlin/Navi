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
    let firstGoal = args.count > 2 ? args[2] : ""
    let screen = CUPerception.perceive(snap, ocr: nil, goal: firstGoal)
    print("app=\(snap.appName ?? "?") title=\(snap.windowTitle ?? "?") url=\(snap.url ?? "-") controls=\(snap.elements.count) text=\(snap.texts.count) offscreen=\(snap.offscreen.count) items=\(screen.items.count)")
    if args.count == 2 || ProcessInfo.processInfo.environment["AXPROBE_TABLE"] != nil {
        let criteria = CUDecide.itemCriteria(CUDecide.Input(goal: firstGoal, screen: screen, history: []))
        for it in screen.items { print("[\(it.index)] \(it.source.rawValue) \(criteria["\(it.index)"] ?? it.text)") }
        for (k, o) in snap.offscreen.enumerated() { print("(off \(k)) \(o.role) “\(o.label.prefix(60))”") }
    }
    guard args.count > 2 else { sem.signal(); return }
    guard Keychain.has(.typesafe) || Keychain.has(.vercelGateway) else { print("Set TYPESAFE_API_KEY (or AI_GATEWAY_API_KEY) to ask Jev."); sem.signal(); return }
    let jev = JevClient()
    let skill = AppSkills.skill(bundleID: snap.bundleID, url: snap.url)
    print("skill=\(skill?.name ?? "none")")
    for goal in args.dropFirst(2) {
        let candidates = TextCandidates.extract(task: goal)
        let input = CUDecide.Input(goal: goal, screen: CUPerception.perceive(snap, ocr: nil, goal: goal), history: [],
                                   shortcuts: AppSkills.keyCombos(for: skill),
                                   apps: candidates.filter { $0.source == "app" }.map(\.text),
                                   sites: candidates.filter { $0.source == "url" || $0.source == "domain" }.map(\.text),
                                   playbook: skill.map { AppSkills.playbook(for: $0, goal: goal) })
        do {
            let (v, req) = try await CUDecide.ask(jev, input)
            let d = CUDecide.decision(v, request: req)
            var lines = ["GOAL “\(goal)”", "  " + CUDecide.statusLine(d, latencyMs: v.latencyMs)]
            for name in ["kind", d?.kind.targetQuestion].compactMap({ $0 }) {
                guard let h = v.heads[name] else { continue }
                lines.append("  \(name): " + h.top(3).map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", "))
            }
            if let d, let t = d.target, d.kind == .clickItem, let i = Int(t.choice), let it = input.screen.items.first(where: { $0.index == i }) {
                lines.append("  → [\(i)] \(it.role) “\(it.text.prefix(60))”")
            }
            lines.append("  irreversible=\(Int(v.isIrreversible * 100))% prohibited=\(Int(v.isProhibited * 100))%")
            print(lines.joined(separator: "\n"))
        } catch { print("GOAL “\(goal)” error: \(error)") }
    }
    sem.signal()
}
sem.wait()
