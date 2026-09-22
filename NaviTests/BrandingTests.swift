import Testing
import Foundation
@testable import Navi

/// "It reads as Navi": result subtitles never show a path, and nothing the
/// panel renders names the engines behind it unless developer mode is on.
struct BrandingTests {

    // MARK: Result subtitles

    @Test func appSubtitleIsKindOrRunningNeverAFolder() {
        #expect(AppIndex.subtitle(isRunning: false) == "App")
        #expect(AppIndex.subtitle(isRunning: true) == "Running")
        let entry = AppEntry(name: "Maps", path: "/System/Applications/Maps.app", bundleID: "com.apple.Maps")
        let row = AppIndex.result(for: entry, score: 1, isRunning: false)
        #expect(row.subtitle == "App")
        #expect(row.subtitle?.contains("/") == false)
        #expect(row.shortcutHint == "⏎ Open")
        #expect(AppIndex.result(for: entry, score: 1, isRunning: true).shortcutHint == "⏎ Switch to")
    }

    @Test func fileSubtitleIsKindAndModifiedDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        let s = FileSearch.subtitle(kind: "PDF document", modified: twoDaysAgo, relativeTo: now, locale: Locale(identifier: "en_US"))
        #expect(s == "PDF document · Modified 2 days ago")
    }

    @Test func fileSubtitleWithoutDateIsJustTheKind() {
        #expect(FileSearch.subtitle(kind: "Folder", modified: nil) == "Folder")
        #expect(FileSearch.subtitle(kind: nil, modified: nil) == "File")
        #expect(FileSearch.subtitle(kind: "  ", modified: nil) == "File")
    }

    @Test func fileSubtitleNeverContainsAPath() {
        let s = FileSearch.subtitle(kind: "Markdown document", modified: Date(), relativeTo: Date())
        #expect(!s.contains("/"))
        #expect(!s.contains("~"))
    }

    @Test func kindDescriptionComesFromTheSystemOrFallsBack() {
        #expect(FileSearch.kindDescription(extension: "pdf", isDirectory: false) == "PDF document")
        #expect(FileSearch.kindDescription(extension: "", isDirectory: true) == "Folder")
        #expect(FileSearch.kindDescription(extension: "", isDirectory: false) == "File")
        // An unknown extension is a dynamic type with no description.
        #expect(FileSearch.kindDescription(extension: "zzqx9", isDirectory: false) == "File")
        #expect(FileSearch.kindDescription(extension: "zzqx9", isDirectory: true) == "Folder")
    }

    // MARK: Panel wording

    @Test func routingStatusIsEmptyForUsersAndFullForDevelopers() {
        let d = RouteDecision(intent: .openApp, confidence: 0.92, probabilities: [.openApp: 0.92], isRisky: false,
                              needsClarification: false, latencyMs: 140, source: .jev)
        #expect(PanelWording.routingStatus(d, developer: false) == "")
        #expect(PanelWording.routingStatus(d, developer: true) == "Jev · Open app 92% · 140 ms")
        #expect(PanelWording.routingStatus(.heuristic(.calculate), developer: true) == "local · Calculate")
        #expect(PanelWording.routingStatus(.heuristic(.calculate), developer: false) == "")
    }

    @Test func pillShowsOnlyTheSafetyNoteToUsers() {
        let safe = RouteDecision(intent: .askQuestion, confidence: 0.9, probabilities: [.askQuestion: 0.9], isRisky: false,
                                 needsClarification: false, latencyMs: 200, source: .jev)
        let risky = RouteDecision(intent: .computerTask, confidence: 0.86, probabilities: [.computerTask: 0.86], isRisky: true,
                                  needsClarification: false, latencyMs: 175, source: .jev)
        #expect(PanelWording.pillText(safe, developer: false) == nil)
        #expect(PanelWording.pillText(risky, developer: false) == "Asks first")
        #expect(PanelWording.pillText(safe, developer: true) == "Ask Navi · 90%")
        #expect(PanelWording.pillText(.heuristic(.openApp), developer: true) == "local")
        #expect(PanelWording.pillText(.heuristic(.openApp), developer: false) == nil)
    }

    @Test func diagnosticLinesAreRecognised() {
        #expect(PanelWording.isDiagnostic("Jev · CLICK [2] 91% · 118 ms"))
        #expect(PanelWording.isDiagnostic("Jev-driven · 14 candidates on screen · walk 12 ms"))
        #expect(PanelWording.isDiagnostic("Handing step to Claude: low confidence"))
        #expect(PanelWording.isDiagnostic("Haiku wrote the field value · 340 ms"))
        #expect(PanelWording.isDiagnostic("Page ready · 212 elements · Google"))
        #expect(!PanelWording.isDiagnostic("Opening Google Chrome"))
        #expect(!PanelWording.isDiagnostic("Working in Notes in the background — keep using your Mac"))
        #expect(!PanelWording.isDiagnostic("Step 2 of 3 · browser"))
        #expect(!PanelWording.isDiagnostic("Using the Messages playbook"))
    }

    @Test func riskTextReadsAsNavi() {
        let risk = "Jev flags this as irreversible (94%): it may send, pay, delete or overwrite something."
        #expect(PanelWording.userFacing(risk) == "This may be hard to undo: it may send, pay, delete or overwrite something.")
        #expect(PanelWording.userFacing("You declined ‘Click Send’ and Jev proposed it again — stopping.")
                == "You declined ‘Click Send’ and Navi proposed it again — stopping.")
        #expect(PanelWording.userFacing("Claude · 812 ms · The field is not focused.") == "Navi · The field is not focused.")
        #expect(!PanelWording.mentionsVendor(PanelWording.userFacing("Jev thinks Claude is stuck — nudging")))
        #expect(PanelWording.userFacing("Opening Google Chrome") == "Opening Google Chrome")
    }

    @Test func routerRowSubtitlesReadAsNavi() {
        #expect(PanelWording.resultSubtitle("Answer with Claude", developer: false) == "Answer this question")
        #expect(PanelWording.resultSubtitle("Add an Anthropic key in Navi → AI Providers", developer: false) == "Finish setting up Navi first")
        #expect(PanelWording.resultSubtitle("Answer with Claude", developer: true) == "Answer with Claude")
        #expect(PanelWording.resultSubtitle("App", developer: false) == "App")
        #expect(PanelWording.resultSubtitle("", developer: false) == nil)
        #expect(PanelWording.resultSubtitle(nil, developer: false) == nil)
    }

    // MARK: Developer section

    @Test func developerSectionIsListedOnlyInDeveloperMode() {
        let before = DeveloperMode.isEnabled
        defer { DeveloperMode.isEnabled = before }
        DeveloperMode.isEnabled = false
        #expect(!SettingsSection.allCases.contains(.providers))
        #expect(SettingsSection.allCases.first == .home)
        DeveloperMode.isEnabled = true
        #expect(SettingsSection.allCases.last == .providers)
        #expect(SettingsSection.providers.title == "Developer")
    }

    // MARK: Usage counters

    @Test func usageCountersCountAnswersAndTasksAndRollOverMonthly() {
        let suite = "BrandingTests.usage.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let sept = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09
        UsageCounters.record(.answer, in: d, now: sept)
        UsageCounters.record(.answer, in: d, now: sept)
        UsageCounters.record(.task, in: d, now: sept)
        let c = UsageCounters.counts(in: d, now: sept)
        #expect(c.answers == 2 && c.tasks == 1)
        let oct = sept.addingTimeInterval(40 * 86_400)
        let next = UsageCounters.counts(in: d, now: oct)
        #expect(next.answers == 0 && next.tasks == 0)
        #expect(UsageCounters.month(of: sept) != UsageCounters.month(of: oct))
    }

    @Test func approvalModeLabelsArePlain() {
        for mode in ApprovalMode.allCases {
            #expect(!PanelWording.mentionsVendor(AgentSettingsView.label(for: mode)))
        }
    }
}
