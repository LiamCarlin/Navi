import Foundation
import Testing
@testable import Navi

@Suite struct CalendarAccountsTests {
    @Test func accountsAreRecognised() {
        #expect(CalendarAccountKind.classify(.exchange, title: "liam@olin.edu") == .exchange)
        #expect(CalendarAccountKind.classify(.calDAV, title: "iCloud") == .iCloud)
        #expect(CalendarAccountKind.classify(.mobileMe, title: "anything") == .iCloud)
        #expect(CalendarAccountKind.classify(.calDAV, title: "liamzcarlin@gmail.com") == .google)
        #expect(CalendarAccountKind.classify(.calDAV, title: "Google") == .google)
        #expect(CalendarAccountKind.classify(.calDAV, title: "liam@outlook.com") == .exchange)
        #expect(CalendarAccountKind.classify(.calDAV, title: "Fastmail") == .other)
        #expect(CalendarAccountKind.classify(.local, title: "On My Mac") == .local)
        #expect(CalendarAccountKind.classify(.subscribed, title: "Holidays") == .subscribed)
        #expect(CalendarAccountKind.classify(.birthdays, title: "Other") == .subscribed)
    }

    @Test func busyByDefaultOnlyForYourOwnCalendars() {
        #expect(CalendarPreferences.defaultCountsAsBusy(isWritable: true, isSubscription: false))
        #expect(!CalendarPreferences.defaultCountsAsBusy(isWritable: false, isSubscription: true))    // holidays, ICS links
        #expect(!CalendarPreferences.defaultCountsAsBusy(isWritable: false, isSubscription: false))   // a colleague's, read-only
    }

    @Test func aChoiceOverridesTheDefault() {
        let overrides = ["outlook-ics": true, "home": false]
        #expect(CalendarPreferences.countsAsBusy(id: "outlook-ics", isWritable: false, isSubscription: true, overrides: overrides))
        #expect(!CalendarPreferences.countsAsBusy(id: "home", isWritable: true, isSubscription: false, overrides: overrides))
        #expect(CalendarPreferences.countsAsBusy(id: "work", isWritable: true, isSubscription: false, overrides: overrides))
    }

    @Test func calendarLinksBecomeWebcal() {
        let outlook = "https://outlook.office365.com/owa/calendar/abc/def/calendar.ics"
        #expect(CalendarPreferences.webcalURL(from: outlook)?.absoluteString
                == "webcal://outlook.office365.com/owa/calendar/abc/def/calendar.ics")
        #expect(CalendarPreferences.webcalURL(from: "  webcal://p01-caldav.icloud.com/published/2/xyz  ")?.scheme == "webcal")
        #expect(CalendarPreferences.webcalURL(from: "http://example.com/cal.ics")?.absoluteString == "webcal://example.com/cal.ics")
        #expect(CalendarPreferences.webcalURL(from: "calendar.google.com/calendar/ical/x/basic.ics")?.host == "calendar.google.com")
        #expect(CalendarPreferences.webcalURL(from: "not a link") == nil)
        #expect(CalendarPreferences.webcalURL(from: "") == nil)
        #expect(CalendarPreferences.webcalURL(from: "ftp://example.com/cal.ics") == nil)
    }

    @Test func menuTitlesNameTheAccount() {
        let work = CalendarInfo(id: "1", title: "Work", color: nil, accountID: "a", accountTitle: "liam@olin.edu",
                                kind: .exchange, isWritable: true, isSubscription: false, countsAsBusy: true)
        #expect(work.menuTitle == "Work · Outlook / Exchange")
        var other = work
        other.kind = .other
        other.accountTitle = "Fastmail"
        #expect(other.menuTitle == "Work · Fastmail")
    }
}
