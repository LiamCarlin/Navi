import AppKit
import Foundation

/// Where a calendar comes from. macOS already syncs Google, Outlook /
/// Microsoft 365 (Exchange) and iCloud accounts added in System Settings →
/// Internet Accounts, and EventKit reads them all, so Navi works with any of
/// them without its own sign-in.
enum CalendarAccountKind: String, Equatable, Sendable {
    case iCloud, google, exchange, local, subscribed, other

    /// EventKit's source type, without importing EventKit here (keeps this testable).
    enum SourceType: Equatable, Sendable { case local, exchange, calDAV, mobileMe, subscribed, birthdays, other }

    static func classify(_ type: SourceType, title: String) -> CalendarAccountKind {
        let t = title.lowercased()
        switch type {
        case .exchange: return .exchange
        case .mobileMe: return .iCloud
        case .local: return .local
        case .subscribed, .birthdays: return .subscribed
        case .calDAV:
            if t == "icloud" || t.hasSuffix("@icloud.com") || t.hasSuffix("@me.com") || t.hasSuffix("@mac.com") { return .iCloud }
            if t.contains("gmail.com") || t.contains("googlemail.com") || t.contains("google") { return .google }
            if t.contains("outlook") || t.contains("hotmail") || t.contains("live.com") || t.contains("office365") { return .exchange }
            return .other
        case .other: return .other
        }
    }

    var label: String {
        switch self {
        case .iCloud: return "iCloud"
        case .google: return "Google"
        case .exchange: return "Outlook / Exchange"
        case .local: return "On My Mac"
        case .subscribed: return "Subscribed"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .iCloud: return "icloud"
        case .google: return "g.circle"
        case .exchange: return "envelope.badge"
        case .local: return "desktopcomputer"
        case .subscribed: return "link"
        case .other: return "calendar"
        }
    }
}

/// One calendar, as the settings and the scheduler card show it.
struct CalendarInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var color: NSColor?
    var accountID: String
    var accountTitle: String
    var kind: CalendarAccountKind
    /// Events can be added to it (not a subscription or someone else's read-only calendar).
    var isWritable: Bool
    /// A subscription or the birthdays calendar: never busy unless the user says so.
    var isSubscription: Bool
    var countsAsBusy: Bool

    /// "Work · Outlook / Exchange"
    var menuTitle: String { "\(title) · \(kind == .other ? accountTitle : kind.label)" }
}

/// An account and its calendars.
struct CalendarAccount: Identifiable, Equatable {
    var id: String
    var title: String
    var kind: CalendarAccountKind
    var calendars: [CalendarInfo]
}

/// The user's calendar choices (Settings → Calendars), read off the main actor.
enum CalendarPreferences {
    static let busyOverridesKey = "schedulerBusyCalendars"
    static let bookingCalendarKey = "schedulerBookingCalendar"

    /// Without a choice, your own writable calendars count; subscriptions don't.
    static func defaultCountsAsBusy(isWritable: Bool, isSubscription: Bool) -> Bool {
        isWritable && !isSubscription
    }

    static func countsAsBusy(id: String, isWritable: Bool, isSubscription: Bool, overrides: [String: Bool]) -> Bool {
        overrides[id] ?? defaultCountsAsBusy(isWritable: isWritable, isSubscription: isSubscription)
    }

    static var overrides: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: busyOverridesKey) as? [String: Bool] ?? [:]
    }

    static func setCountsAsBusy(_ on: Bool, for id: String) {
        var all = overrides
        all[id] = on
        UserDefaults.standard.set(all, forKey: busyOverridesKey)
    }

    /// The calendar new meetings go to; nil = Calendar's own default.
    static var bookingCalendarID: String? {
        get { UserDefaults.standard.string(forKey: bookingCalendarKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue ?? "", forKey: bookingCalendarKey) }
    }

    /// A published calendar link as Calendar subscribes to it: "https://…/calendar.ics"
    /// or "webcal://…" → webcal://…; nil for anything that isn't a link.
    static func webcalURL(from link: String) -> URL? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("https://") { s = "webcal://" + s.dropFirst("https://".count) }
        else if lower.hasPrefix("http://") { s = "webcal://" + s.dropFirst("http://".count) }
        else if lower.hasPrefix("webcals://") { s = "webcal://" + s.dropFirst("webcals://".count) }
        else if !lower.hasPrefix("webcal://") {
            guard lower.contains("."), !lower.contains("://") else { return nil }
            s = "webcal://" + s
        }
        guard let url = URL(string: s), let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
