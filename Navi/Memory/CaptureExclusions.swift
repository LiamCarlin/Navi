import AppKit
import ApplicationServices
import CoreGraphics

/// What screen memory never looks at. Checked before a frame is captured, so an
/// excluded moment is never screenshotted, OCR'd, triaged or stored.
///
/// - **Apps** — the built-in list (password managers, Keychain, Passwords, System
///   Settings, the system's authentication dialogs) can't be turned off; the user adds
///   their own in Settings → Privacy & Data. Windows of excluded apps are also cut out
///   of every frame (`ScreenCapture.captureMainDisplay(excludingBundleIDs:)`), so a
///   password manager sitting behind another window is never in a screenshot either.
/// - **Sites** — a domain matches itself and its subdomains (`chase.com` covers
///   `secure.chase.com`). Needs the browser's URL, which Navi reads only once the
///   user allowed Automation for that browser.
/// - **Private windows** — incognito / private / InPrivate browser windows.
/// - **Secure fields** — while a password field has keyboard focus.
enum CaptureExclusions {
    /// Never captured, whatever the settings say.
    static let builtInApps: [(bundleID: String, name: String)] = [
        ("com.apple.Passwords", "Passwords"),
        ("com.apple.keychainaccess", "Keychain Access"),
        ("com.apple.systempreferences", "System Settings"),
        ("com.apple.SecurityAgent", "Authentication dialogs"),
        ("com.apple.LocalAuthentication.UIAgent", "Touch ID prompts"),
        ("com.1password.1password", "1Password"),
        ("com.agilebits.onepassword7", "1Password 7"),
        ("com.agilebits.onepassword-osx", "1Password 6"),
        ("com.bitwarden.desktop", "Bitwarden"),
        ("com.lastpass.LastPass", "LastPass"),
        ("org.keepassxc.keepassxc", "KeePassXC"),
        ("in.sinew.Enpass-Desktop", "Enpass"),
        ("me.proton.pass.electron", "Proton Pass"),
        ("com.dashlane.dashlanephonefinal", "Dashlane"),
    ]
    static let builtInBundleIDs: Set<String> = Set(builtInApps.map(\.bundleID))

    /// The default "never capture" sites (removable): password-manager web vaults.
    static let defaultSites = ["1password.com", "bitwarden.com", "lastpass.com", "passwords.google.com",
                               "keepersecurity.com", "dashlane.com"]

    // MARK: Apps

    static func isExcludedApp(_ bundleID: String, userExcluded: Set<String>) -> Bool {
        builtInBundleIDs.contains(bundleID) || userExcluded.contains(bundleID)
    }

    // MARK: Sites

    /// "https://www.Chase.com/login?x=1" / "www.chase.com" / ".chase.com" → "chase.com".
    /// Returns nil for anything that isn't a host name.
    static func normalizeSite(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        guard s.contains("."), s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return s
    }

    /// Host of a page URL, lowercased, without `www.`.
    static func host(of url: String) -> String? {
        guard let comps = URLComponents(string: url), let h = comps.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Whether `url` is on one of `sites` (exact host or a subdomain of it).
    static func isExcludedSite(url: String?, sites: [String]) -> Bool {
        guard let url, let host = host(of: url) else { return false }
        return sites.compactMap(normalizeSite).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: Private browsing

    /// Private windows that say so in their title (Firefox, Edge, Tor, Orion…).
    static func isPrivateWindowTitle(_ title: String?) -> Bool {
        guard let t = title?.lowercased(), !t.isEmpty else { return false }
        return t.hasSuffix("private browsing") || t.contains("— private browsing") || t.contains("- private browsing")
            || t.contains("[inprivate]") || t.hasSuffix("inprivate") || t.hasSuffix("(incognito)") || t.hasSuffix("— incognito")
    }

    /// Chromium browsers and Arc report a private window over Apple Events (`mode` /
    /// `incognito`). Only call once Automation for `bundleID` is allowed; never on the main thread.
    static func isPrivateWindowViaScript(bundleID: String) -> Bool {
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        let source: String
        switch bundleID {
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
            source = "tell application \"\(name ?? "Google Chrome")\" to return mode of front window"
        case "company.thebrowser.Browser":
            source = "tell application \"\(name ?? "Arc")\" to return incognito of front window"
        default:
            return false
        }
        guard let script = NSAppleScript(source: source) else { return false }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        guard err == nil else { return false }
        let value = (result.stringValue ?? "").lowercased()
        return value == "incognito" || value == "true" || result.booleanValue
    }

    // MARK: Secure input & session

    /// A password field has keyboard focus (`AXSecureTextField`, native or on a web page).
    /// (Not `IsSecureEventInputEnabled()`: Terminal's Secure Keyboard Entry and apps that leak
    /// it would switch Recall off system-wide without the user knowing why.)
    static var isSecureInputActive: Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return isSecureRole(role as? String, subrole: subrole as? String)
    }

    static func isSecureRole(_ role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// False while another user's session owns the screen (fast user switching) or
    /// before login completes.
    static var isOurSessionOnConsole: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let on = dict[kCGSessionOnConsoleKey as String] as? Bool { return on }
        if let on = dict[kCGSessionOnConsoleKey as String] as? NSNumber { return on.boolValue }
        return true
    }
}
