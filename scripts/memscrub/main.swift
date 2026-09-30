import AppKit
import Foundation

// memscrub — one-off redaction of personal identifiers already in screen memory.
// Dry run by default: prints what would change (kinds and counts, never values).
//   build/memscrub                     # dry run on ~/Library/Application Support/Navi + the vault
//   build/memscrub --apply             # redact (quit Navi first)
//   build/memscrub --db DIR --vault DIR [--apply]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let apply = args.contains("--apply")
let home = FileManager.default.homeDirectoryForCurrentUser
let dbDir = option("--db").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    ?? home.appendingPathComponent("Library/Application Support/Navi", isDirectory: true)
let savedVault = UserDefaults(suiteName: "com.liamcarlin.navi")?.string(forKey: "memoryVaultPath").flatMap { $0.isEmpty ? nil : $0 }
let vaultDir = URL(fileURLWithPath: ((option("--vault") ?? savedVault ?? "~/Navi Vault") as NSString).expandingTildeInPath, isDirectory: true)

guard FileManager.default.fileExists(atPath: dbDir.appendingPathComponent("memory.sqlite").path) else {
    FileHandle.standardError.write("No memory.sqlite in \(dbDir.path)\n".data(using: .utf8)!); exit(1)
}
if apply, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.liamcarlin.navi").isEmpty,
   option("--db") == nil {
    FileHandle.standardError.write("Navi is running — quit it first so the database can be rewritten.\n".data(using: .utf8)!); exit(1)
}

do {
    let store = try MemoryStore(directory: dbDir)
    let cleanup = PersonalDataCleanup(store: store, vaultRoot: vaultDir)
    let plan = try cleanup.plan()
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    print("database: \(dbDir.path)/memory.sqlite")
    print("vault:    \(vaultDir.path)")
    print("frames:   \(plan.frameIDs.count) of \(plan.framesScanned) with text would be reduced to app + time stubs")
    print("sessions: \(plan.sessions.count) of \(plan.sessionsScanned) hold identifiers")
    for fix in plan.sessions {
        let dropped = (fix.before.entities.count - fix.after.entities.count) + (fix.before.topics.count - fix.after.topics.count)
        let facts = fix.keptKeyFacts.map { " · key facts kept \($0.count)" } ?? ""
        print("  #\(fix.before.id) \(f.string(from: fix.before.start)) “\(fix.after.title)” — \(fix.kinds.sorted().map(\.rawValue).joined(separator: ", "))"
              + " · summary \(fix.before.summary == fix.after.summary ? "unchanged" : "redacted") · entities/topics dropped \(dropped)\(facts)")
    }
    guard apply else { print("\nDry run — nothing changed. Re-run with --apply to redact."); exit(0) }
    let report = try cleanup.apply(plan)
    print("\nApplied:\n\(report)")
} catch {
    FileHandle.standardError.write("memscrub failed: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1)
}
