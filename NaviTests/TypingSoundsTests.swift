import Foundation
import Testing
@testable import Navi

@Suite struct TypingSoundsTests {
    // MARK: Key classes

    @Test func keyCodesMapToKinds() {
        #expect(TypingKeyKind.kind(forKeyCode: 49) == .space)
        #expect(TypingKeyKind.kind(forKeyCode: 36) == .returnKey)
        #expect(TypingKeyKind.kind(forKeyCode: 76) == .returnKey)   // keypad Enter
        #expect(TypingKeyKind.kind(forKeyCode: 51) == .delete)      // ⌫
        #expect(TypingKeyKind.kind(forKeyCode: 117) == .delete)     // ⌦
        #expect(TypingKeyKind.kind(forKeyCode: 55) == .modifier)    // ⌘
        #expect(TypingKeyKind.kind(forKeyCode: 63) == .modifier)    // fn
        #expect(TypingKeyKind.kind(forKeyCode: 0) == .key)          // a
        #expect(TypingKeyKind.kind(forKeyCode: 48) == .key)         // Tab
    }

    @Test func charactersMapToKinds() {
        #expect(TypingKeyKind.kind(for: "a") == .key)
        #expect(TypingKeyKind.kind(for: " ") == .space)
        #expect(TypingKeyKind.kind(for: "\n") == .returnKey)
        #expect(TypingKeyKind.kind(for: "é") == .key)
    }

    // MARK: Pacing

    @Test func agentSpeedTypingIsThinnedToAHumanPace() {
        // InputController types a character every 8 ms: 200 characters in 1.6 s.
        var pacer = TypingSoundPacer(seed: 1)
        let voiced = (0..<200).filter { pacer.shouldVoice(.key, at: Double($0) * 0.008) }
        #expect(voiced.first == 0)                         // the first key is always heard
        #expect(voiced.count >= Int(1.6 / TypingSoundPacer.gap.upperBound))
        #expect(voiced.count <= Int(1.6 / TypingSoundPacer.gap.lowerBound) + 1)
        let gaps = zip(voiced, voiced.dropFirst()).map { Double($1 - $0) * 0.008 }
        #expect(gaps.allSatisfy { $0 >= TypingSoundPacer.gap.lowerBound - 0.0001 })
        #expect(Set(gaps).count > 1)                       // jittered, not metronomic
    }

    @Test func humanPacedKeysAreAllVoiced() {
        var pacer = TypingSoundPacer(seed: 2)
        let voiced = (0..<10).filter { pacer.shouldVoice(.key, at: Double($0) * 0.15) }
        #expect(voiced.count == 10)
    }

    @Test func returnIsHeardEvenRightAfterAKey() {
        var pacer = TypingSoundPacer(seed: 3)
        let first = pacer.shouldVoice(.key, at: 0)
        let tooSoon = pacer.shouldVoice(.key, at: 0.008)
        let returnKey = pacer.shouldVoice(.returnKey, at: 0.04)
        let doublePress = pacer.shouldVoice(.returnKey, at: 0.05)
        #expect(first)
        #expect(!tooSoon)
        #expect(returnKey)
        #expect(!doublePress)  // a double press merges
    }

    // MARK: Bursts

    @Test func emptyTextHasNoBurst() {
        #expect(TypingSoundPacer.burst(for: "", seed: 1).isEmpty)
        #expect(TypingSoundPacer.burst(for: "   ", seed: 1).isEmpty)
    }

    @Test func burstFollowsTheTextAtANaturalPace() {
        let events = TypingSoundPacer.burst(for: "hi there", seed: 7)
        #expect(events.map(\.kind) == [.key, .key, .space, .key, .key, .key, .key, .key])
        #expect(events.first?.offset == 0)
        let gaps = zip(events, events.dropFirst()).map { $1.offset - $0.offset }
        #expect(gaps.allSatisfy { $0 >= 0.06 && $0 <= 0.2 })
    }

    @Test func longTextIsCapped() {
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        let events = TypingSoundPacer.burst(for: text, maxDuration: 0.9, seed: 9)
        #expect(!events.isEmpty)
        #expect(events.count < 20)
        #expect(events.allSatisfy { $0.offset <= 0.9 })
    }

    @Test func burstIsDeterministicForASeed() {
        #expect(TypingSoundPacer.burst(for: "hello world", seed: 42) == TypingSoundPacer.burst(for: "hello world", seed: 42))
        #expect(TypingSoundPacer.burst(for: "hello world", seed: 42) != TypingSoundPacer.burst(for: "hello world", seed: 43))
    }

    // MARK: Synthesis

    @Test func bankVoicesEveryKindWithDistinctVariants() {
        let bank = TypingSoundSynthesizer.bank()
        for kind in TypingKeyKind.allCases {
            let hits = try! #require(bank[kind])
            #expect(hits.count == TypingSoundSynthesizer.variantsPerKind)
            for hit in hits {
                #expect(hit.frameCount > 1_000)
                #expect(hit.left.count == hit.right.count)
                let peak = (hit.left + hit.right).map(abs).max() ?? 0
                #expect(peak > 0.2 && peak < 1.3)          // audible, and nowhere near a blown-out click
            }
            #expect(Set(hits.map(\.frameCount)).count > 1)  // varied, so fast typing never sounds looped
        }
    }

    @Test func spaceBarIsCentred() {
        let space = try! #require(TypingSoundSynthesizer.bank()[.space]?.first)
        #expect(zip(space.left, space.right).allSatisfy { abs($0 - $1) < 1e-5 })
    }
}
