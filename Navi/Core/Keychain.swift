import Foundation
import Security

/// Thin Keychain wrapper for API keys. Keys are stored as generic passwords
/// under the service "com.liamcarlin.navi" and are never written to disk in
/// plain text or to UserDefaults.
enum Keychain {
    static let service = "com.liamcarlin.navi"

    enum Key: String, CaseIterable {
        case typesafe = "TYPESAFE_API_KEY"      // Jev (direct)
        case vercelGateway = "AI_GATEWAY_API_KEY" // Jev via Vercel AI Gateway (typesafe-ai/jev)
        case anthropic = "ANTHROPIC_API_KEY"    // Claude
        case gemini = "GEMINI_API_KEY"          // cheap vision digest (optional)
        case openai = "OPENAI_API_KEY"          // optional
        case deepgram = "DEEPGRAM_API_KEY"      // optional voice
        case firecrawl = "FIRECRAWL_API_KEY"    // optional web
    }

    static func get(_ key: Key) -> String? {
        // Environment variables win so developers can run without touching Keychain.
        if let env = ProcessInfo.processInfo.environment[key.rawValue], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: Key, value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.settings.error("Keychain set failed for \(key.rawValue): \(status)") }
        return status == errSecSuccess
    }

    static func has(_ key: Key) -> Bool { !(get(key) ?? "").isEmpty }
}
