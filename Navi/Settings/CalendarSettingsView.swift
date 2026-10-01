import EventKit
import SwiftUI

/// Settings → Calendars: every calendar macOS syncs (iCloud, Google, Outlook /
/// Exchange, On My Mac, subscriptions), which ones count as busy when Navi
/// looks for a free time, where new meetings are booked, and how to add more —
/// an account in Internet Accounts, or a published calendar link.
struct CalendarSettingsView: View {
    @State private var accounts: [CalendarAccount] = []
    @State private var access: Permissions.State = ScheduleCalendar.shared.status
    @State private var bookingID: String = CalendarPreferences.bookingCalendarID ?? ""
    @State private var link = ""
    @State private var linkError: String?

    private var writable: [CalendarInfo] { accounts.flatMap(\.calendars).filter(\.isWritable) }

    var body: some View {
        FormPage(title: "Calendars",
                 subtitle: "Navi reads every calendar on your Mac — iCloud, Google, Outlook — to find a time when everyone's free.") {
            if access != .granted {
                Section {
                    HStack {
                        Label("Navi needs Calendar access", systemImage: "calendar.badge.exclamationmark")
                        Spacer()
                        Button(access == .denied ? "Open Settings" : "Allow") { requestAccess() }
                    }
                }
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Google, Outlook or iCloud account")
                        Text("Add it once in System Settings › Internet Accounts — choose Google, Microsoft Exchange (Outlook, Microsoft 365, Outlook.com) or iCloud, and turn on Calendars. Its calendars show up here by themselves.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Internet Accounts") { ScheduleCalendar.openInternetAccounts() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Calendar link (ICS or webcal)", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(subscribe)
                        Button("Subscribe", action: subscribe)
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(linkError ?? "For a calendar you can't add as an account: Outlook on the web › Settings › Calendar › Shared calendars › Publish, or Google Calendar › Settings › “Secret address in iCal format”. Subscribed calendars are read-only; turn on “Busy” to use them for free time.")
                        .font(.caption)
                        .foregroundStyle(linkError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Add a calendar")
            }

            if !writable.isEmpty {
                Section {
                    Picker("Book new meetings in", selection: $bookingID) {
                        Text("Default calendar").tag("")
                        ForEach(writable) { cal in
                            Text(cal.menuTitle).tag(cal.id)
                        }
                    }
                    .onChange(of: bookingID) { _, id in CalendarPreferences.bookingCalendarID = id.isEmpty ? nil : id }
                } header: {
                    Text("Booking")
                } footer: {
                    Text("You can still pick another calendar for a single meeting on the ⌘Space card. Guests get the invite from that calendar's account.")
                }
            }

            ForEach(accounts) { account in
                Section {
                    ForEach(account.calendars) { cal in
                        Toggle(isOn: busyBinding(cal)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(cal.color.map { Color(nsColor: $0) } ?? .gray)
                                    .frame(width: 10, height: 10)
                                Text(cal.title)
                                if !cal.isWritable {
                                    Text(cal.isSubscription ? "subscribed" : "read-only")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Label(account.kind == .other || account.kind == .local || account.kind == .subscribed
                          || account.title.caseInsensitiveCompare(account.kind.label) == .orderedSame
                          ? account.kind.label : "\(account.kind.label) · \(account.title)",
                          systemImage: account.kind.symbol)
                } footer: {
                    if account.id == accounts.last?.id {
                        Text("On = Navi treats events in that calendar as busy when it suggests times. Holidays, birthdays and other subscriptions start off.")
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
    }

    private func busyBinding(_ cal: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { accounts.flatMap(\.calendars).first { $0.id == cal.id }?.countsAsBusy ?? cal.countsAsBusy },
            set: { on in
                CalendarPreferences.setCountsAsBusy(on, for: cal.id)
                reload()
            })
    }

    private func reload() {
        access = ScheduleCalendar.shared.status
        accounts = ScheduleCalendar.shared.accounts()
        if !bookingID.isEmpty, !writable.contains(where: { $0.id == bookingID }) { bookingID = "" }
    }

    private func requestAccess() {
        if access == .denied {
            Opener.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            return
        }
        Task { @MainActor in
            _ = await ScheduleCalendar.shared.requestAccess()
            reload()
        }
    }

    private func subscribe() {
        if ScheduleCalendar.subscribe(to: link) {
            link = ""
            linkError = nil
        } else {
            linkError = "That doesn't look like a calendar link — it should start with https:// or webcal://."
        }
    }
}
