import Testing
import Foundation
@testable import Navi

struct KeychainTests {
    @Test func environmentOverridesStoreAndNeverBlocks() {
        setenv("FIRECRAWL_API_KEY", "fc_env", 1)
        defer { unsetenv("FIRECRAWL_API_KEY") }
        #expect(Keychain.get(.firecrawl) == "fc_env")
        #expect(Keychain.has(.firecrawl))
    }

    @Test func setUpdatesCacheImmediately() {
        unsetenv("OPENAI_API_KEY")
        let before = Keychain.get(.openai)
        Keychain.set(.openai, value: "sk-test-cache")
        #expect(Keychain.get(.openai) == "sk-test-cache")   // synchronous cache, no Keychain round-trip
        Keychain.set(.openai, value: before)                // restore
    }
}
