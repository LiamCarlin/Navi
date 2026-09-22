import CryptoKit
import Foundation
import Testing
@testable import Navi

struct UpdaterTests {
    // MARK: Version comparison

    @Test func semanticVersionOrdering() {
        func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }
        #expect(v("0.1.0") < v("0.2.0"))
        #expect(v("0.1.0") < v("0.1.1"))
        #expect(v("1.9.9") < v("1.10.0"))          // numeric, not lexicographic
        #expect(v("1.99.99") < v("2.0.0"))
        #expect(v("1.0") == v("1.0.0"))             // missing components are zero
        #expect(v("v2.0.0") == v("2.0.0"))          // leading v ignored
        #expect(v("1.0.0+42") == v("1.0.0"))        // build metadata ignored
        #expect(v("1.0.0-beta.1") < v("1.0.0"))     // prerelease sorts below the release
        #expect(v("1.0.0-beta.1") < v("1.0.0-beta.2"))
        #expect(v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(v("1.0.0-beta") < v("1.0.0-beta.1"))
        #expect(!(v("1.0.0") < v("1.0.0")))
        #expect(v("0.1.0").description == "0.1.0")
    }

    @Test func semanticVersionRejectsGarbage() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1.x") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1..2") == nil)
    }

    @Test func offersOnlyNewerUnskippedVersions() {
        #expect(Updater.shouldOffer(remote: "0.2.0", local: "0.1.0", skipped: nil, userInitiated: false))
        #expect(!Updater.shouldOffer(remote: "0.1.0", local: "0.1.0", skipped: nil, userInitiated: false))
        #expect(!Updater.shouldOffer(remote: "0.0.9", local: "0.1.0", skipped: nil, userInitiated: true))
        #expect(!Updater.shouldOffer(remote: "0.2.0", local: "0.1.0", skipped: "0.2.0", userInitiated: false))
        #expect(Updater.shouldOffer(remote: "0.2.0", local: "0.1.0", skipped: "0.2.0", userInitiated: true))   // manual check ignores skip
        #expect(Updater.shouldOffer(remote: "0.3.0", local: "0.1.0", skipped: "0.2.0", userInitiated: false))
        #expect(!Updater.shouldOffer(remote: "bogus", local: "0.1.0", skipped: nil, userInitiated: true))
    }

    @Test func osRequirement() {
        #expect(Updater.osSatisfies(nil))
        #expect(Updater.osSatisfies("10.0"))
        #expect(!Updater.osSatisfies("99.0"))
    }

    // MARK: Appcast

    @Test func appcastDecodes() throws {
        let json = """
        {"version":"0.2.0","build":"7","url":"https://navi.app/downloads/Navi-0.2.0.dmg",
         "sha256":"ABCDEF","ed25519":"c2ln","notes":"- Faster answers\\n- Bug fixes","minOS":"26.0","published":"2026-09-22T00:00:00Z"}
        """
        let a = try JSONDecoder().decode(Appcast.self, from: Data(json.utf8))
        #expect(a.version == "0.2.0")
        #expect(a.build == "7")
        #expect(a.url.host == "navi.app")
        #expect(a.notes?.contains("Faster") == true)
        #expect(a.minOS == "26.0")

        // Optional fields may be absent.
        let minimal = """
        {"version":"0.2.0","build":"7","url":"https://navi.app/x.dmg","sha256":"00","ed25519":""}
        """
        let m = try JSONDecoder().decode(Appcast.self, from: Data(minimal.utf8))
        #expect(m.notes == nil && m.minOS == nil)
    }

    // MARK: Signatures

    @Test func verifiesCryptoKitSignedPayload() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data("Navi DMG bytes".utf8)
        let sig = try key.signature(for: payload).base64EncodedString()
        let digest = UpdateVerifier.sha256Hex(payload)

        try UpdateVerifier.verify(payload, sha256: digest, signatureBase64: sig, publicKeyBase64: pub)
        try UpdateVerifier.verify(payload, sha256: digest.uppercased(), signatureBase64: sig, publicKeyBase64: pub)

        // Tampered bytes: the digest catches it first.
        #expect(throws: UpdateVerifier.Failure.digestMismatch) {
            try UpdateVerifier.verify(Data("Navi DMG bytes!".utf8), sha256: digest, signatureBase64: sig, publicKeyBase64: pub)
        }
        // Right digest, signature from another key: rejected.
        let other = try Curve25519.Signing.PrivateKey().signature(for: payload).base64EncodedString()
        #expect(throws: UpdateVerifier.Failure.badSignature) {
            try UpdateVerifier.verify(payload, sha256: digest, signatureBase64: other, publicKeyBase64: pub)
        }
        // Signature that is not base64 / wrong length: rejected, not crashed.
        #expect(throws: UpdateVerifier.Failure.badSignature) {
            try UpdateVerifier.verify(payload, sha256: digest, signatureBase64: "not base64!", publicKeyBase64: pub)
        }
        #expect(throws: UpdateVerifier.Failure.badPublicKey) {
            try UpdateVerifier.verify(payload, sha256: digest, signatureBase64: sig, publicKeyBase64: "AAAA")
        }
    }

    /// Fixture produced with the exact commands scripts/gen-appcast.sh runs:
    ///   openssl genpkey -algorithm ed25519 -out k.pem
    ///   printf 'navi-appcast-fixture' > f
    ///   openssl pkey -in k.pem -pubout -outform DER | tail -c 32 | base64        → public key
    ///   openssl pkeyutl -sign -rawin -inkey k.pem -in f | base64                  → signature
    /// so CryptoKit is proven to accept what openssl emits.
    @Test func verifiesOpenSSLFixture() throws {
        let payload = Data("navi-appcast-fixture".utf8)
        let pub = "rQkZVQiHlmY1mxtBUe9Ow0Cn6yKnSNRVkJuvrufg9Cw="
        let sig = "pN8E69QKuXmL9KBb+bdIjZfnASKwZvGntWkz5EJ52Y/937w3HW6nYR7u/mN4VlP4usnTSfbDxMEv23A3ixxjDg=="
        let sha = "5245e05d1de50ecdc57d411408ada386ec3735ee8f361350b4bf8ebf61c09eda"
        #expect(UpdateVerifier.sha256Hex(payload) == sha)
        try UpdateVerifier.verify(payload, sha256: sha, signatureBase64: sig, publicKeyBase64: pub)
        #expect(throws: UpdateVerifier.Failure.badSignature) {
            try UpdateVerifier.verify(payload, sha256: sha, signatureBase64: sig)   // Navi's real key did not sign this
        }
    }

    @Test func builtInPublicKeyIsWellFormed() {
        let raw = Data(base64Encoded: UpdateVerifier.publicKeyBase64)
        #expect(raw?.count == 32)
        #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: raw ?? Data())) != nil)
    }

    @Test func feedURLDefaultsAndOverride() {
        let d = UserDefaults.standard
        let before = d.string(forKey: "updateFeedURL")
        defer { d.set(before, forKey: "updateFeedURL") }
        d.removeObject(forKey: "updateFeedURL")
        #expect(NaviSettings.updateFeedURL.absoluteString == "https://navi.app/appcast.json")
        d.set("http://localhost:8765/appcast.json", forKey: "updateFeedURL")
        #expect(NaviSettings.updateFeedURL.port == 8765)
        d.set("not a url", forKey: "updateFeedURL")
        #expect(NaviSettings.updateFeedURL.host == "navi.app")
    }
}
