import AppKit
import Combine
import Foundation

/// State behind the scheduler card that drops down from the ⌘Space bar when
/// the query asks to put something on the calendar. Typing keeps updating it
/// (`update`); what the user picks on the card (a slot, the day, the length)
/// sticks until they type a different one.
@MainActor
final class SchedulerModel: ObservableObject {
    enum Booking: Equatable {
        case idle, booking
        case booked(String)
        case failed(String)
    }

    enum StatusTone { case neutral, good, warning }

    struct Status: Equatable {
        var text: String
        var symbol: String
        var tone: StatusTone
    }

    @Published private(set) var request: ScheduleRequest
    @Published private(set) var day: Date
    @Published private(set) var start: Date? = nil
    @Published private(set) var duration: Int
    @Published private(set) var people: [SchedulePerson] = []
    @Published private(set) var me: SchedulePerson? = nil
    @Published private(set) var myBusy: [ScheduleInterval] = []
    @Published private(set) var availability: [String: PersonAvailability] = [:]
    @Published private(set) var suggestions: [Date] = []
    @Published private(set) var isLoading = false
    @Published private(set) var calendarAccess: Permissions.State
    @Published private(set) var contactsAccess: Permissions.State
    @Published private(set) var calendarColor: NSColor? = nil
    /// Where this meeting will be booked: Settings → Calendars' choice, or one picked on the card.
    @Published private(set) var bookingCalendarID: String? = CalendarPreferences.bookingCalendarID
    @Published private(set) var bookingCalendar: CalendarInfo? = nil
    /// Every calendar that can take the meeting, across accounts (the card's picker).
    @Published private(set) var writableCalendars: [CalendarInfo] = []
    @Published private(set) var booking: Booking = .idle
    @Published private(set) var exampleNames: [String] = []
    @Published var videoOn: Bool
    /// The inline "paste your meeting link" row is open.
    @Published var editingVideoLink = false
    @Published var videoLinkDraft = ""

    /// Called after a booking with everything done (toast + close the panel).
    var onBooked: ((String) -> Void)?

    let calendar: Calendar
    private let now: () -> Date
    private let directory: ScheduleDirectory
    private let store: ScheduleCalendar
    private var manualDay = false
    private var manualStart = false
    private var manualDuration = false
    private var loadTask: Task<Void, Never>?
    private var loadedKey: String?

    init(request: ScheduleRequest, calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         directory: ScheduleDirectory = .shared, store: ScheduleCalendar = .shared) {
        self.request = request
        self.calendar = calendar
        self.now = now
        self.directory = directory
        self.store = store
        self.day = request.resolvedDay(now: now(), calendar: calendar)
        self.duration = request.durationMinutes ?? request.defaultDuration
        self.calendarAccess = store.status
        self.contactsAccess = directory.status
        self.videoOn = !Self.videoLink.isEmpty
        reload()
    }

    // MARK: Settings

    static let videoLinkKey = "schedulerVideoLink"

    /// The user's own meeting link (Zoom, Meet, FaceTime…) put on events with video on.
    static var videoLink: String {
        UserDefaults.navi.string(forKey: videoLinkKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Derived

    var window: ScheduleInterval {
        SchedulePlanner.window(for: day, time: manualStart ? nil : request.time, duration: duration, calendar: calendar)
    }

    var end: Date? { start.map { $0.addingTimeInterval(TimeInterval(duration * 60)) } }

    var title: String {
        ScheduleRequest.title(activity: request.activity, names: people.map(\.firstName))
    }

    /// Everyone's visible busy time, for "who's free".
    private var allBusy: [ScheduleInterval] {
        myBusy + availability.values.flatMap(\.busy)
    }

    var youConflict: Bool {
        guard let start else { return false }
        return SchedulePlanner.conflicts(start: start, duration: duration, busy: myBusy)
    }

    /// Guests whose visible calendar clashes with the slot.
    var busyGuests: [SchedulePerson] {
        guard let start else { return [] }
        return people.filter { p in
            SchedulePlanner.conflicts(start: start, duration: duration, busy: availability[p.id]?.busy ?? [])
        }
    }

    var hasConflict: Bool { youConflict || !busyGuests.isEmpty }

    var canBook: Bool {
        start != nil && calendarAccess == .granted && booking != .booking && !isBooked
    }

    var isBooked: Bool { if case .booked = booking { return true }; return false }

    /// "Tomorrow", "Today", "Friday", "Mon 5 Oct".
    var dayTitle: String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now()), to: day).day ?? 99
        if (0..<7).contains(days) { return day.formatted(.dateTime.weekday(.wide)) }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "30 Sep", shown muted after `dayTitle`.
    var daySubtitle: String { day.formatted(.dateTime.day().month(.abbreviated)) }

    /// "Wed 30 Sep · 12:30 PM – 1:15 PM · 2 guests"
    var slotSummary: String? {
        guard let start, let end else { return nil }
        var parts = [start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                     "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"]
        if !people.isEmpty { parts.append(people.count == 1 ? "1 guest" : "\(people.count) guests") }
        return parts.joined(separator: " · ")
    }

    /// The line under the event card.
    var status: Status {
        switch booking {
        case .booking: return Status(text: "Booking…", symbol: "calendar.badge.clock", tone: .neutral)
        case .booked(let text): return Status(text: text, symbol: "checkmark.circle.fill", tone: .good)
        case .failed(let text): return Status(text: text, symbol: "exclamationmark.circle.fill", tone: .warning)
        case .idle: break
        }
        if calendarAccess != .granted {
            return Status(text: "Allow Calendar access to see when everyone's free", symbol: "calendar", tone: .neutral)
        }
        if isLoading && myBusy.isEmpty && availability.isEmpty {
            return Status(text: "Checking calendars…", symbol: "info.circle.fill", tone: .neutral)
        }
        guard start != nil else {
            return suggestions.isEmpty
                ? Status(text: "Nobody's free long enough — try another day", symbol: "info.circle.fill", tone: .neutral)
                : Status(text: "Pick a time", symbol: "info.circle.fill", tone: .neutral)
        }
        if youConflict { return Status(text: "You already have something then", symbol: "exclamationmark.circle.fill", tone: .warning) }
        let busy = busyGuests
        if !busy.isEmpty {
            let names = Self.list(busy.map(\.firstName))
            return Status(text: "\(names) \(busy.count == 1 ? "is" : "are") busy then", symbol: "exclamationmark.circle.fill", tone: .warning)
        }
        let noEmail = people.filter { $0.email == nil }
        if !noEmail.isEmpty {
            let names = Self.list(noEmail.map(\.firstName))
            return Status(text: "No email for \(names) — they won't get an invite", symbol: "info.circle.fill", tone: .neutral)
        }
        let hidden = people.filter { if case .sharedOnly = availability[$0.id] { return true }; return false }
        if !hidden.isEmpty {
            let names = Self.list(hidden.map(\.firstName))
            return Status(text: "You're free · can't see \(names)'s calendar", symbol: "info.circle.fill", tone: .neutral)
        }
        return Status(text: people.isEmpty ? "You're free then" : "Everyone's free", symbol: "checkmark.circle.fill", tone: .good)
    }

    nonisolated static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Input

    /// The query changed. What was typed wins over an earlier pick only when
    /// that part of the text changed.
    func update(_ new: ScheduleRequest) {
        let old = request
        request = new
        if new.day != old.day { manualDay = false }
        if new.time != old.time || new.partOfDay != old.partOfDay || new.day != old.day { manualStart = false }
        if new.durationMinutes != old.durationMinutes { manualDuration = false }
        if !manualDay { day = new.resolvedDay(now: now(), calendar: calendar) }
        if !manualDuration { duration = new.durationMinutes ?? new.defaultDuration }
        if case .failed = booking { booking = .idle }
        reload()
    }

    func shiftDay(_ delta: Int) {
        guard let next = calendar.date(byAdding: .day, value: delta, to: day),
              next >= calendar.startOfDay(for: now()) else { return }
        day = next
        manualDay = true
        manualStart = false
        reload()
    }

    func changeDuration(_ direction: Int) {
        duration = SchedulePlanner.adjustedDuration(duration, by: direction)
        manualDuration = true
        recomputeSlots()
    }

    func select(start newStart: Date) {
        start = SchedulePlanner.snap(newStart, in: window, duration: duration)
        manualStart = true
    }

    /// ↑/↓: step through the suggested times.
    func cycleSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let current = start.flatMap { s in suggestions.firstIndex(of: s) }
        let next = current.map { ($0 + delta + suggestions.count) % suggestions.count } ?? (delta > 0 ? 0 : suggestions.count - 1)
        start = suggestions[next]
        manualStart = true
    }

    func toggleVideo() {
        if Self.videoLink.isEmpty {
            videoLinkDraft = ""
            editingVideoLink = true
        } else {
            videoOn.toggle()
        }
    }

    func saveVideoLink() {
        let link = videoLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.navi.set(link, forKey: Self.videoLinkKey)
        editingVideoLink = false
        videoOn = !link.isEmpty
    }

    // MARK: Permissions

    func requestCalendarAccess() {
        if store.status == .denied {
            Opener.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            return
        }
        Task {
            _ = await store.requestAccess()
            calendarAccess = store.status
            loadedKey = nil
            reload()
        }
    }

    func requestContactsAccess() {
        if directory.status == .denied {
            Opener.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
            return
        }
        Task {
            _ = await directory.requestAccess()
            contactsAccess = directory.status
            loadedKey = nil
            reload()
        }
    }

    // MARK: Booking

    /// Book this one in another calendar (Settings → Calendars sets the usual one).
    func selectBookingCalendar(_ id: String) {
        bookingCalendarID = id
        bookingCalendar = writableCalendars.first { $0.id == id }
        calendarColor = bookingCalendar?.color
        loadedKey = nil   // a work account may pick guests' work emails
        reload()
    }

    func book() {
        guard let start, let end, canBook else {
            if calendarAccess != .granted { requestCalendarAccess() }
            return
        }
        booking = .booking
        let title = self.title
        let guests = people
        let link = videoOn ? Self.videoLink : ""
        let store = self.store
        let calendarID = bookingCalendarID
        Task {
            do {
                let result = try await store.book(title: title, start: start, end: end,
                                                  videoLink: link.isEmpty ? nil : link, guests: guests,
                                                  calendarID: calendarID)
                let when = start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                if let error = result.inviteError {
                    Log.app.error("scheduler: booked without guests: \(error, privacy: .public)")
                    booking = .booked("Booked \(when) — couldn't add guests, open it in Calendar to invite them")
                    ScheduleCalendar.reveal(eventIdentifier: result.eventIdentifier)
                } else {
                    let invited = result.invited.isEmpty ? "" : " · invited \(Self.list(result.invited))"
                    booking = .booked("Booked \(when) in \(result.calendarTitle)\(invited)")
                    onBooked?("Booked")
                }
            } catch {
                booking = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Loading

    /// Re-reads contacts and calendars when the day or the people change (a
    /// moment after the last keystroke); otherwise just recomputes the slots.
    private func reload() {
        let key = "\(day.timeIntervalSinceReferenceDate)|\(request.people.joined(separator: ","))|\(calendarAccess)|\(contactsAccess)"
        guard key != loadedKey else { recomputeSlots(); return }
        loadedKey = key
        loadTask?.cancel()
        isLoading = true
        recomputeSlots()
        let typed = request.people
        let day = self.day
        let calendar = self.calendar
        let directory = self.directory
        let store = self.store
        let calendarID = bookingCalendarID
        let wantExamples = exampleNames.isEmpty && !request.hasDetails
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (SchedulePerson?, [SchedulePerson], DayAvailability, CalendarInfo?, [String], [CalendarInfo]) in
                let domain = store.accountDomain(bookingIn: calendarID)
                let people = typed.map { directory.person(for: $0, preferredDomain: domain) }
                // The same contact typed twice ("jil and jilles") is one guest.
                var seen = Set<String>()
                let unique = people.filter { seen.insert($0.id).inserted }
                let availability = store.availability(on: day, for: unique, calendar: calendar)
                let examples = wantExamples ? directory.exampleNames() : []
                let writable = store.accounts().flatMap(\.calendars).filter(\.isWritable)
                return (directory.me(), unique, availability, store.bookingTarget(calendarID), examples, writable)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.me = loaded.0
            self.people = loaded.1
            self.myBusy = loaded.2.mine
            self.availability = loaded.2.others
            self.bookingCalendar = loaded.3
            self.calendarColor = loaded.3?.color
            self.writableCalendars = loaded.5
            if !loaded.4.isEmpty { self.exampleNames = loaded.4 }
            self.isLoading = false
            self.recomputeSlots()
        }
    }

    private func recomputeSlots() {
        let window = self.window
        let free = SchedulePlanner.freeStarts(in: window, busy: allBusy, duration: duration,
                                              notBefore: SchedulePlanner.notBefore(now()))
        let preferred = SchedulePlanner.preferredWindow(for: day, partOfDay: request.partOfDay,
                                                        activity: request.activity, calendar: calendar)
        suggestions = SchedulePlanner.suggestions(from: free, duration: duration, preferred: preferred)
        if !manualStart {
            // Wait for the calendars before proposing a time nobody asked for.
            let typedTime = request.time != nil
            start = typedTime || !isLoading
                ? SchedulePlanner.initialStart(time: request.time, day: day, suggestions: suggestions, calendar: calendar)
                : nil
        }
    }
}
