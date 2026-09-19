import Testing
import Foundation
@testable import Navi

struct AppIndexTests {
    let index = RouterFakes.appIndex()

    private func top(_ q: String) -> AppMatch? { index.search(q, limit: 1, running: [], launchCounts: [:]).first }
    private func score(_ q: String, _ name: String) -> Double {
        let e = RouterFakes.apps.first { $0.name == name }!
        return AppIndex.baseScore(query: AppIndex.normalize(q), entry: e)
    }

    @Test func exactNameScoresOne() { #expect(score("maps", "Maps") == 1.0); #expect(top("maps")?.entry.name == "Maps") }
    @Test func caseInsensitive() { #expect(top("MAPS")?.entry.name == "Maps") }
    @Test func prefix() { #expect(score("ma", "Maps") == 0.95); #expect(score("ma", "Magnet") == 0.95) }
    @Test func prefixTieBreaksOnShorterName() { #expect(top("ma")?.entry.name == "Mail") }
    @Test func acronym() { #expect(score("gc", "Google Chrome") == 0.85); #expect(top("gc")?.entry.name == "Google Chrome") }
    @Test func wordStart() { #expect(score("chrome", "Google Chrome") == 0.98); #expect(score("studio", "Visual Studio Code") == 0.85) }
    @Test func subsequenceScaledByCompactness() {
        let s = score("chrm", "Google Chrome")
        #expect(s > 0.4 && s < 0.6)
        #expect(score("gce", "Google Chrome") < s)   // wider span → lower
    }
    @Test func noMatchIsZero() { #expect(score("zzz", "Maps") == 0); #expect(index.search("qwxyz").isEmpty) }
    @Test func aliases() {
        #expect(top("settings")?.entry.name == "System Settings")
        #expect(top("preferences")?.entry.name == "System Settings")
        #expect(top("calc")?.entry.name == "Calculator")
        #expect(top("code")?.entry.name == "Visual Studio Code")
        #expect(top("vscode")?.entry.name == "Visual Studio Code")
    }
    @Test func stripsLaunchVerbs() {
        #expect(AppIndex.normalize("open Maps") == "maps")
        #expect(AppIndex.normalize("Launch chrome app") == "chrome")
        #expect(top("open slack")?.entry.name == "Slack")
        #expect(top("start terminal")?.entry.name == "Terminal")
    }
    @Test func runningAndLaunchCountBoost() {
        let plain = index.search("ma", limit: 3, running: [], launchCounts: [:])
        #expect(plain.first?.entry.name == "Mail")
        let boosted = index.search("ma", limit: 3, running: ["com.apple.Maps"], launchCounts: ["com.apple.Maps": 2])
        #expect(boosted.first?.entry.name == "Maps")
        #expect((boosted.first?.score ?? 0) > 0.95)
    }
    @Test func limitRespected() { #expect(index.search("m", limit: 2).count == 2) }
}
