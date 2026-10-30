import Contacts
import Foundation

/// The user's own details from their contact card (Contacts → My Card), for the forms of their
/// own errands: "order me a burger" needs a delivery address, "pizza near me" a ZIP. The browser
/// runner's text helper sees them only for a field that asks for one of them
/// (`NAVI_USER_PROFILE_JSON`), never Jev's state. Nothing here asks for Contacts access:
/// without it, or without a card, there is nothing.
enum UserCard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (fields: [String: String], at: Date)?
    static let ttl: TimeInterval = 600

    /// name, email, phone, address (one line), street, city, state, zip, country — what the card has.
    static func fields(now: Date = Date()) -> [String: String] {
        guard !TestHost.isActive, CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [:] }
        lock.lock()
        if let c = cached, now.timeIntervalSince(c.at) < ttl { lock.unlock(); return c.fields }
        lock.unlock()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey,
                    CNContactPhoneNumbersKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
        var out: [String: String] = [:]
        if let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) {
            out = fields(given: me.givenName, family: me.familyName,
                         emails: me.emailAddresses.map { ($0.label, $0.value as String) },
                         phones: me.phoneNumbers.map { ($0.label, $0.value.stringValue) },
                         addresses: me.postalAddresses.map { ($0.label, $0.value) })
        }
        lock.lock(); cached = (out, now); lock.unlock()
        return out
    }

    /// The card as fields; home before work, a mobile number before others.
    static func fields(given: String, family: String, emails: [(String?, String)], phones: [(String?, String)],
                       addresses: [(String?, CNPostalAddress)]) -> [String: String] {
        var out: [String: String] = [:]
        let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { out["name"] = name }
        if let e = emails.first(where: { $0.0 == CNLabelHome })?.1 ?? emails.first?.1 { out["email"] = e }
        if let p = phones.first(where: { $0.0 == CNLabelPhoneNumberMobile || $0.0 == CNLabelPhoneNumberiPhone })?.1 ?? phones.first?.1 { out["phone"] = p }
        if let a = addresses.first(where: { $0.0 == CNLabelHome })?.1 ?? addresses.first?.1 {
            let street = a.street.replacingOccurrences(of: "\n", with: ", ")
            let cityLine = [a.city, [a.state, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: ", ")
            let line = [street, cityLine].filter { !$0.isEmpty }.joined(separator: ", ")
            if !line.isEmpty { out["address"] = line }
            for (k, v) in [("street", street), ("city", a.city), ("state", a.state), ("zip", a.postalCode), ("country", a.country)] where !v.isEmpty {
                out[k] = v
            }
        }
        return out
    }

    /// For the browser runner; nil when there is nothing.
    static func runnerJSON() -> String? {
        let f = fields()
        guard !f.isEmpty, let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
