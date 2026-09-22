import Foundation
import Security

/// API-key store.
///
/// All keys live in **one** Keychain item (service "com.liamcarlin.navi",
/// account "keys", JSON body). One item means one "Navi wants to access…"
/// prompt per build instead of one per key — Navi is ad-hoc signed, so every
/// rebuilt binary is a new identity to the Keychain ACL.
///
/// The item is read **once, off the main thread** (`preload()`, called at
/// launch) into an in-memory cache. `get`/`has` only ever read the cache, so a
/// pending Keychain prompt can never stall the UI: until it is answered, keys
/// simply read as absent and the UI says so. `set` updates the cache
/// immediately and writes through in the background.
///
/// Environment variables (`TYPESAFE_API_KEY`, …) override the store for dev.
enum Keychain {
    static let service = "com.liamcarlin.navi"
    static let account = "keys"

    enum Key: String, CaseIterable {
        case typesafe = "TYPESAFE_API_KEY"      // Jev (direct)
        case vercelGateway = "AI_GATEWAY_API_KEY" // Jev via Vercel AI Gateway (typesafe-ai/jev)
        case anthropic = "ANTHROPIC_API_KEY"    // Claude
        case gemini = "GEMINI_API_KEY"          // cheap vision digest (optional)
        case openai = "OPENAI_API_KEY"          // optional
        case deepgram = "DEEPGRAM_API_KEY"      // optional voice
        case firecrawl = "FIRECRAWL_API_KEY"    // optional web
        case naviAccess = "NAVI_ACCESS_TOKEN"   // Navi Cloud session (1 h JWT)
        case naviRefresh = "NAVI_REFRESH_TOKEN" // Navi Cloud refresh token
    }

    enum LoadState: Equatable { case notLoaded, loading, loaded, failed(OSStatus) }

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var state: LoadState = .notLoaded
    private static let queue = DispatchQueue(label: "navi.keychain", qos: .userInitiated)

    // MARK: Reads (never block)

    static func get(_ key: Key) -> String? {
        if let env = ProcessInfo.processInfo.environment[key.rawValue], !env.isEmpty { return env }
        lock.lock(); defer { lock.unlock() }
        if state == .notLoaded { startLoadLocked() }
        return cache[key.rawValue]
    }

    static func has(_ key: Key) -> Bool { !(get(key) ?? "").isEmpty }

    static var loadState: LoadState { lock.lock(); defer { lock.unlock() }; return state }

    /// Kick off the one-time background read. Call early at launch.
    static func preload() {
        lock.lock(); defer { lock.unlock() }
        if state == .notLoaded { startLoadLocked() }
    }

    private static func startLoadLocked() {
        state = .loading
        queue.async { load() }
    }

    private static func load() {
        var loaded: [String: String] = [:]
        var status: OSStatus = errSecSuccess
        if let data = readItem(account: account, status: &status),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            loaded = dict
        } else if status == errSecItemNotFound {
            // Migrate legacy one-item-per-key layout (pre 2026-09-19).
            var migrated: [String: String] = [:]
            for k in Key.allCases {
                var s: OSStatus = errSecSuccess
                if let d = readItem(account: k.rawValue, status: &s), let v = String(data: d, encoding: .utf8), !v.isEmpty {
                    migrated[k.rawValue] = v
                }
            }
            loaded = migrated
            // Legacy items are left in place: deleting them would be one more
            // ACL prompt each, and they are harmless.
            if !migrated.isEmpty, writeItem(migrated) {
                Log.settings.info("Keychain: migrated \(migrated.count) legacy key items into one")
            }
        }
        lock.lock()
        cache = loaded
        state = (status == errSecSuccess || status == errSecItemNotFound) ? .loaded : .failed(status)
        lock.unlock()
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.settings.error("Keychain read failed: \(status)")
        }
        NotificationCenter.default.post(name: .naviKeysChanged, object: nil)
    }

    // MARK: Writes

    @discardableResult
    static func set(_ key: Key, value: String?) -> Bool {
        lock.lock()
        if let value, !value.isEmpty { cache[key.rawValue] = value } else { cache.removeValue(forKey: key.rawValue) }
        let snapshot = cache
        lock.unlock()
        queue.async {
            if !writeItem(snapshot) { Log.settings.error("Keychain write failed for \(key.rawValue)") }
            NotificationCenter.default.post(name: .naviKeysChanged, object: key.rawValue)
        }
        return true
    }

    // MARK: SecItem plumbing (background queue only)

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readItem(account: String, status: inout OSStatus) -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        status = SecItemCopyMatching(q as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    private static func writeItem(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return false }
        let base = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Navi API keys"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

}

extension Notification.Name {
    static let naviKeysChanged = Notification.Name("navi.keysChanged")
}
