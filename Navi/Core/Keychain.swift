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
///
/// Under the test host (`TestHost`) the store is in-memory only: it starts empty
/// and never reads or writes the real item.
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

    /// No SecItem calls at all: under the test host, and (Debug) a run against a
    /// local cloud — no ACL prompt, no writes to the real item.
    static var isInMemory: Bool {
        if TestHost.isActive { return true }
        #if DEBUG
        if DevCloud.current != nil { return true }
        #endif
        return false
    }

    static var loadState: LoadState { lock.lock(); defer { lock.unlock() }; return state }

    /// Kick off the one-time background read. Call early at launch.
    static func preload() {
        lock.lock(); defer { lock.unlock() }
        if state == .notLoaded { startLoadLocked() }
    }

    private static func startLoadLocked() {
        if isInMemory { state = .loaded; return }
        state = .loading
        queue.async { load() }
    }

    /// Writes made before the first read finished (a `navi://auth/callback`
    /// that launched the app, a key pasted while the ACL prompt is up). They are
    /// replayed over what the read returns, so neither side loses the other's keys.
    private static var pendingWrites: [String: String?] = [:]

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
        for (k, v) in pendingWrites {
            if let v { loaded[k] = v } else { loaded.removeValue(forKey: k) }
        }
        pendingWrites = [:]
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
        let stored: String? = (value?.isEmpty ?? true) ? nil : value
        if let stored { cache[key.rawValue] = stored } else { cache.removeValue(forKey: key.rawValue) }
        if state == .notLoaded { startLoadLocked() }
        if state == .loading { pendingWrites[key.rawValue] = stored }
        lock.unlock()
        if isInMemory {
            NotificationCenter.default.post(name: .naviKeysChanged, object: key.rawValue)
            return true
        }
        queue.async {
            // Runs after the first read (same serial queue), so the snapshot is the
            // merged item — never a cache that missed the keys still being read.
            lock.lock()
            let snapshot = cache
            let readFailed: Bool
            if case .failed = state { readFailed = true } else { readFailed = false }
            lock.unlock()
            if readFailed {
                // Writing now would replace an item we couldn't read with a partial copy.
                Log.settings.error("Keychain write skipped for \(key.rawValue): the item couldn't be read")
            } else if !writeItem(snapshot) {
                Log.settings.error("Keychain write failed for \(key.rawValue)")
            }
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
