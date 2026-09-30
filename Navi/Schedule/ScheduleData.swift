import AppKit
import Contacts
import EventKit
import Foundation

/// Someone on the invite: a contact matched from what was typed, or just the typed name.
struct SchedulePerson: Identifiable, Equatable, Sendable {
    var id: String
    /// As typed ("jilles").
    var typed: String
    /// "Jilles van Gurp"
    var name: String
    /// "Jilles"
    var firstName: String
    var email: String?
    var imageData: Data?
    var isContact: Bool

    static func typedOnly(_ typed: String) -> SchedulePerson {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") {
            let local = String(trimmed.split(separator: "@").first ?? Substring(trimmed))
            return SchedulePerson(id: "email:\(trimmed.lowercased())", typed: typed, name: trimmed,
                                  firstName: local.capitalized, email: trimmed, imageData: nil, isContact: false)
        }
        let name = trimmed.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return SchedulePerson(id: "typed:\(trimmed.lowercased())", typed: typed, name: name,
                              firstName: String(name.split(separator: " ").first ?? Substring(name)),
                              email: nil, imageData: nil, isContact: false)
    }
}

/// What can be seen of someone's day.
enum PersonAvailability: Equatable, Sendable {
    /// Their calendar is visible in Calendar (a shared or delegated calendar).
    case known([ScheduleInterval])
    /// Only the meetings on your calendar they're invited to.
    case sharedOnly([ScheduleInterval])

    var busy: [ScheduleInterval] {
        switch self {
        case .known(let b), .sharedOnly(let b): return b
        }
    }
}

struct DayAvailability: Sendable {
    var mine: [ScheduleInterval]
    var others: [String: PersonAvailability]
}

struct BookingResult: Sendable {
    var eventIdentifier: String
    var calendarTitle: String
    /// First names of the guests added to the event.
    var invited: [String]
    /// Set when the event was saved but the guests could not be added.
    var inviteError: String?
}

// MARK: - Contacts

/// Resolves typed names to contacts (name, email, photo). Contacts calls block,
/// so callers run these off the main actor.
final class ScheduleDirectory: @unchecked Sendable {
    static let shared = ScheduleDirectory()

    private let store = CNContactStore()
    private let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
        CNContactEmailAddressesKey, CNContactThumbnailImageDataKey,
    ] as [CNKeyDescriptor]
    private let lock = NSLock()
    private var cache: [String: SchedulePerson] = [:]

    var status: Permissions.State {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .granted   // e.g. limited access: lookups still work for the shared contacts
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        if granted { lock.lock(); cache.removeAll(); lock.unlock() }
        return granted
    }

    /// The best contact for a typed name — prefers first-name matches and
    /// contacts with an email; an email in `preferredDomain` wins among theirs.
    func person(for typed: String, preferredDomain: String?) -> SchedulePerson {
        let key = typed.lowercased().trimmingCharacters(in: .whitespaces)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        var result = SchedulePerson.typedOnly(typed)
        if !key.contains("@"), key.count >= 2, status == .granted,
           let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: key), keysToFetch: keys) {
            let ranked = found.map { c in
                (c, Self.matchScore(typed: key, given: c.givenName, family: c.familyName, nickname: c.nickname,
                                    hasEmail: !c.emailAddresses.isEmpty))
            }
            if let best = ranked.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 })?.0 {
                let emails = best.emailAddresses.map { $0.value as String }
                let first = best.givenName.isEmpty ? (best.nickname.isEmpty ? best.familyName : best.nickname) : best.givenName
                let full = [best.givenName, best.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                result = SchedulePerson(id: best.identifier, typed: typed, name: full.isEmpty ? first : full,
                                        firstName: first, email: Self.preferredEmail(emails, domain: preferredDomain),
                                        imageData: best.thumbnailImageData, isContact: true)
            }
        }
        // A typed prefix ("jil") can match someone better once more is typed; only cache full matches.
        if result.isContact, result.firstName.lowercased() == key || result.name.lowercased() == key {
            lock.lock(); cache[key] = result; lock.unlock()
        }
        return result
    }

    /// You, from the "me" card: photo and name for the first row.
    func me() -> SchedulePerson? {
        guard status == .granted, let c = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return nil }
        return SchedulePerson(id: c.identifier, typed: "", name: c.givenName, firstName: c.givenName,
                              email: c.emailAddresses.first.map { $0.value as String },
                              imageData: c.thumbnailImageData, isContact: true)
    }

    /// First names of a couple of contacts with an email, for the card's examples.
    func exampleNames(limit: Int = 2) -> [String] {
        guard status == .granted else { return [] }
        var names: [String] = []
        let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor])
        try? store.enumerateContacts(with: request) { contact, stop in
            if !contact.givenName.isEmpty, !contact.emailAddresses.isEmpty, !names.contains(contact.givenName) {
                names.append(contact.givenName)
            }
            if names.count >= limit { stop.pointee = true }
        }
        return names
    }

    /// 0 when the contact doesn't match. Exact first name > first-name prefix >
    /// nickname/last name prefix; an email breaks ties (only they can be invited).
    static func matchScore(typed: String, given: String, family: String, nickname: String, hasEmail: Bool) -> Double {
        let t = typed.lowercased()
        let full = "\(given) \(family)".lowercased()
        var score: Double
        if given.lowercased() == t || full == t { score = 3 }
        else if given.lowercased().hasPrefix(t) || full.hasPrefix(t) { score = 2 }
        else if nickname.lowercased().hasPrefix(t) || family.lowercased().hasPrefix(t) { score = 1 }
        else { return 0 }
        return score + (hasEmail ? 0.5 : 0)
    }

    static func preferredEmail(_ emails: [String], domain: String?) -> String? {
        if let domain = domain?.lowercased(), let work = emails.first(where: { $0.lowercased().hasSuffix("@" + domain) }) {
            return work
        }
        return emails.first
    }
}

// MARK: - Calendar

/// Reads busy times from Calendar (EventKit) and books the event. Guests are
/// added through Calendar's AppleScript (`make new attendee`), which EventKit
/// can't do; the calendar account then sends the invitations.
final class ScheduleCalendar: @unchecked Sendable {
    static let shared = ScheduleCalendar()

    private let store = EKEventStore()
    private let lock = NSLock()

    var status: Permissions.State {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .unknown
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted {
            lock.lock()
            store.reset()   // calendars load only after access is granted
            lock.unlock()
        }
        return granted
    }

    /// "cloudflare.com" when the meeting goes to a work account: picks guests' work emails.
    func accountDomain(bookingIn calendarID: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted, let title = bookingCalendar(calendarID)?.source?.title,
              let at = title.lastIndex(of: "@") else { return nil }
        return String(title[title.index(after: at)...]).lowercased()
    }

    /// The calendar the meeting will be booked in (the chosen one, else Calendar's default).
    func bookingTarget(_ calendarID: String?) -> CalendarInfo? {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted, let c = bookingCalendar(calendarID) else { return nil }
        return Self.info(c, overrides: CalendarPreferences.overrides)
    }

    /// Every calendar macOS syncs — iCloud, Google, Outlook / Exchange, On My Mac,
    /// subscriptions — by account.
    func accounts() -> [CalendarAccount] {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted else { return [] }
        let overrides = CalendarPreferences.overrides
        var byID: [String: CalendarAccount] = [:]
        for c in store.calendars(for: .event) {
            let info = Self.info(c, overrides: overrides)
            byID[info.accountID, default: CalendarAccount(id: info.accountID, title: info.accountTitle,
                                                           kind: info.kind, calendars: [])].calendars.append(info)
        }
        return byID.values
            .map { account in
                var a = account
                a.calendars.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return a
            }
            .sorted { (Self.accountOrder($0.kind), $0.title.lowercased()) < (Self.accountOrder($1.kind), $1.title.lowercased()) }
    }

    /// The chosen calendar when it can still take events, else Calendar's default. Call under `lock`.
    private func bookingCalendar(_ calendarID: String?) -> EKCalendar? {
        if let calendarID, let c = store.calendar(withIdentifier: calendarID), Self.isWritable(c) { return c }
        return store.defaultCalendarForNewEvents
    }

    static func isSubscription(_ c: EKCalendar) -> Bool { c.type == .subscription || c.type == .birthday }
    static func isWritable(_ c: EKCalendar) -> Bool { c.allowsContentModifications && !isSubscription(c) }

    static func info(_ c: EKCalendar, overrides: [String: Bool]) -> CalendarInfo {
        let accountTitle = c.source?.title ?? "Other"
        let writable = isWritable(c)
        let subscription = isSubscription(c)
        return CalendarInfo(id: c.calendarIdentifier, title: c.title, color: NSColor(cgColor: c.cgColor),
                            accountID: c.source?.sourceIdentifier ?? accountTitle, accountTitle: accountTitle,
                            kind: CalendarAccountKind.classify(sourceType(c.source?.sourceType), title: accountTitle),
                            isWritable: writable, isSubscription: subscription,
                            countsAsBusy: CalendarPreferences.countsAsBusy(id: c.calendarIdentifier, isWritable: writable,
                                                                          isSubscription: subscription, overrides: overrides))
    }

    static func sourceType(_ type: EKSourceType?) -> CalendarAccountKind.SourceType {
        switch type {
        case .local?: return .local
        case .exchange?: return .exchange
        case .calDAV?: return .calDAV
        case .mobileMe?: return .mobileMe
        case .subscribed?: return .subscribed
        case .birthdays?: return .birthdays
        default: return .other
        }
    }

    static func accountOrder(_ kind: CalendarAccountKind) -> Int {
        switch kind {
        case .iCloud: return 0
        case .google: return 1
        case .exchange: return 2
        case .other: return 3
        case .local: return 4
        case .subscribed: return 5
        }
    }

    /// System Settings → Internet Accounts, where Google, Outlook (Microsoft Exchange) and
    /// iCloud accounts are added; their calendars then show up in Navi by themselves.
    static func openInternetAccounts() {
        Opener.open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
    }

    /// Hands a published calendar link (an Outlook or Google ICS address) to Calendar,
    /// which asks to subscribe. False when it isn't a link.
    @discardableResult
    static func subscribe(to link: String) -> Bool {
        guard let url = CalendarPreferences.webcalURL(from: link) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Your busy time and each guest's for the day (start of day).
    func availability(on day: Date, for people: [SchedulePerson], calendar cal: Calendar) -> DayAvailability {
        lock.lock(); defer { lock.unlock() }
        guard status == .granted, let dayEnd = cal.date(byAdding: .day, value: 1, to: day) else {
            return DayAvailability(mine: [], others: [:])
        }
        let calendars = store.calendars(for: .event)
        var theirs: [String: [EKCalendar]] = [:]
        for p in people {
            theirs[p.id] = calendars.filter { Self.calendarTitle($0.title, belongsTo: p) }
        }
        let theirIDs = Set(theirs.values.flatMap { $0.map(\.calendarIdentifier) })
        // Every account's calendars that count as busy (Settings → Calendars; by default your own).
        let overrides = CalendarPreferences.overrides
        let mine = calendars.filter { c in
            !theirIDs.contains(c.calendarIdentifier)
                && CalendarPreferences.countsAsBusy(id: c.calendarIdentifier, isWritable: Self.isWritable(c),
                                                    isSubscription: Self.isSubscription(c), overrides: overrides)
        }
        func busyEvents(_ cals: [EKCalendar]) -> [EKEvent] {
            guard !cals.isEmpty else { return [] }
            let predicate = store.predicateForEvents(withStart: day, end: dayEnd, calendars: cals)
            return store.events(matching: predicate).filter(Self.blocksTime)
        }
        func intervals(_ events: [EKEvent]) -> [ScheduleInterval] {
            events.map { event in
                let start: Date = event.startDate ?? day
                let end: Date = event.endDate ?? dayEnd
                return ScheduleInterval(start: max(start, day), end: min(end, dayEnd))
            }
        }
        let myEvents = busyEvents(mine)
        var others: [String: PersonAvailability] = [:]
        for p in people {
            if let cals = theirs[p.id], !cals.isEmpty {
                others[p.id] = .known(intervals(busyEvents(cals)))
            } else {
                let shared = myEvents.filter { ev in ev.attendees?.contains { Self.participant($0, is: p) } ?? false }
                others[p.id] = .sharedOnly(intervals(shared))
            }
        }
        return DayAvailability(mine: intervals(myEvents), others: others)
    }

    /// Saves the event to `calendarID` (else Calendar's default), then adds the guests with an email.
    func book(title: String, start: Date, end: Date, videoLink: String?, guests: [SchedulePerson],
              calendarID: String?) async throws -> BookingResult {
        let saved: (id: String, uid: String?, calendar: String) = try {
            lock.lock(); defer { lock.unlock() }
            guard status == .granted else { throw NaviError.other("Navi needs Calendar access to book this.") }
            guard let calendar = bookingCalendar(calendarID) else {
                throw NaviError.other("No calendar to book in — pick one in Navi › Calendars.")
            }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.calendar = calendar
            if let videoLink, let url = URL(string: videoLink), url.scheme != nil {
                event.url = url
                event.location = videoLink
                event.notes = "Join: \(videoLink)"
            }
            try store.save(event, span: .thisEvent, commit: true)
            return (event.calendarItemIdentifier, event.calendarItemExternalIdentifier, calendar.title)
        }()

        let invitees = guests.filter { $0.email != nil }
        var result = BookingResult(eventIdentifier: saved.id, calendarTitle: saved.calendar, invited: [], inviteError: nil)
        guard !invitees.isEmpty else { return result }
        guard let uid = saved.uid, !uid.isEmpty else {
            result.inviteError = "Calendar didn't give the event an id to add guests to"
            return result
        }
        let script = Self.attendeeScript(uid: uid, calendarTitle: saved.calendar, emails: invitees.compactMap(\.email))
        do {
            do {
                _ = try await AgentCustomTools.runAppleScript(script, timeout: 20)
            } catch {
                // Calendar may not have seen the new event yet (it was just launched); once more.
                try await Task.sleep(for: .milliseconds(1500))
                _ = try await AgentCustomTools.runAppleScript(script, timeout: 20)
            }
            result.invited = invitees.map(\.firstName)
        } catch {
            Log.app.error("scheduler: adding guests failed: \(error.localizedDescription, privacy: .public)")
            result.inviteError = error.localizedDescription
        }
        return result
    }

    /// Shows the event in Calendar.
    static func reveal(eventIdentifier: String) {
        let id = eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventIdentifier
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }

    static func blocksTime(_ event: EKEvent) -> Bool {
        if event.isAllDay || event.availability == .free || event.status == .canceled { return false }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
        return true
    }

    static func participant(_ p: EKParticipant, is person: SchedulePerson) -> Bool {
        let address = p.url.absoluteString.lowercased().replacingOccurrences(of: "mailto:", with: "")
        if let email = person.email?.lowercased(), address == email { return true }
        return person.isContact && (p.name ?? "").lowercased() == person.name.lowercased()
    }

    /// A colleague's calendar shows up in Calendar under their email (or name).
    static func calendarTitle(_ title: String, belongsTo person: SchedulePerson) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        if let email = person.email?.lowercased(), t == email || t.contains("<\(email)>") { return true }
        return person.isContact && person.name.contains(" ") && t == person.name.lowercased()
    }

    /// Finds the saved event in Calendar by its uid and adds each guest.
    static func attendeeScript(uid: String, calendarTitle: String, emails: [String]) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = [
            "tell application \"Calendar\"",
            "  set theEvent to missing value",
            "  repeat with c in (every calendar whose name is \(quoted(calendarTitle)))",
            "    try",
            "      set theEvent to (first event of c whose uid is \(quoted(uid)))",
            "      exit repeat",
            "    end try",
            "  end repeat",
            "  if theEvent is missing value then error \"Calendar could not find the new event\"",
            "  tell theEvent",
        ]
        for email in emails {
            lines.append("    make new attendee at end of attendees with properties {email:\(quoted(email))}")
        }
        lines += ["  end tell", "end tell"]
        return lines.joined(separator: "\n")
    }
}
