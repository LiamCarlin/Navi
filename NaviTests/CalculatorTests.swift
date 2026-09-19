import Testing
import Foundation
@testable import Navi

struct CalculatorTests {
    // Fixed "now": Saturday Sep 19 2026 10:00 in Los Angeles — used for date/time cases.
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let now: Date = {
        var c = Calendar(identifier: .gregorian); c.timeZone = la
        return c.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 10, minute: 0))!
    }()

    private func answer(_ q: String) -> String? {
        Calculator.evaluate(q, now: Self.now, timeZone: Self.la)?.answer
    }

    // MARK: Arithmetic

    @Test func multiplies() { #expect(answer("12*34") == "408") }
    @Test func xAsMultiply() { #expect(answer("12x34") == "408"); #expect(answer("3 x 4") == "12") }
    @Test func precedenceAndParens() { #expect(answer("2+3*4") == "14"); #expect(answer("(2+3)*4") == "20") }
    @Test func power() { #expect(answer("2^10") == "1,024"); #expect(answer("2**3**2") == "512") }
    @Test func floatingDivision() { #expect(answer("7/2") == "3.5"); #expect(answer("1/3") == "0.333333") }
    @Test func percentOf() { #expect(answer("12% of 340") == "40.8") }
    @Test func plusPercent() { #expect(answer("15 + 20%") == "18"); #expect(answer("100 - 25%") == "75") }
    @Test func bareNumberIsNotMath() { #expect(answer("42") == nil); #expect(answer("2024") == nil); #expect(answer("-5") == nil) }
    @Test func wordsAreNotMath() { #expect(answer("maps") == nil); #expect(answer("what is love") == nil); #expect(answer("1-800-flowers") == nil) }
    @Test func divisionByZeroIsNil() { #expect(answer("1/0") == nil); #expect(answer("5/(2-2)") == nil) }
    @Test func functions() { #expect(answer("sqrt(16)") == "4"); #expect(answer("abs(-3)+1") == "4"); #expect(answer("sqrt(-1)") == nil) }
    @Test func unaryMinus() { #expect(answer("5*-3") == "-15"); #expect(answer("-2+5") == "3") }
    @Test func grouping() { #expect(answer("1000*1000") == "1,000,000"); #expect(answer("1,000 + 1") == "1,001") }
    @Test func malformedIsNil() { #expect(answer("2+") == nil); #expect(answer("(2+3") == nil); #expect(answer("2 3") == nil); #expect(answer("foo(2)") == nil) }
    @Test func whatIsPrefix() { #expect(answer("what is 6*7?") == "42"); #expect(answer("=3+3") == "6") }
    @Test func modulo() { #expect(answer("10 mod 3") == "1"); #expect(answer("10 % 3") == "1") }

    // MARK: Units

    @Test func kmToMiles() {
        let r = Calculator.evaluate("5 km in miles")
        #expect(r?.kind == .unit)
        #expect(r?.answer.hasPrefix("3.1069") == true)
        #expect(r?.answer.hasSuffix("mi") == true)
    }
    @Test func fahrenheitToCelsius() { #expect(Calculator.evaluate("72 f to c")?.answer.hasPrefix("22.2222") == true) }
    @Test func cupsToMl() { #expect(Calculator.evaluate("3 cups in ml")?.answer == "720 mL") }   // Foundation cup = 240 mL
    @Test func lbToKg() { #expect(Calculator.evaluate("10 lb to kg")?.answer == "4.5359 kg") }
    @Test func inchesAsUnitNotSeparator() {
        #expect(Calculator.evaluate("12 in to cm")?.answer == "30.48 cm")
        #expect(Calculator.evaluate("1 ft in inches")?.answer == "12 in")
    }
    @Test func incompatibleUnitsAreNil() { #expect(Calculator.evaluate("5 km in kg") == nil); #expect(Calculator.evaluate("5 foo in bar") == nil) }
    @Test func dataUnits() { #expect(Calculator.evaluate("2 gb in mb")?.answer == "2,000 MB") }

    // MARK: Currency (parse only — no network)

    @Test func parsesCurrency() {
        #expect(Calculator.parseCurrency("20 usd in eur") == .init(amount: 20, from: "USD", to: "EUR"))
        #expect(Calculator.parseCurrency("$20 in eur") == .init(amount: 20, from: "USD", to: "EUR"))
        #expect(Calculator.parseCurrency("100 euros to dollars") == .init(amount: 100, from: "EUR", to: "USD"))
        #expect(Calculator.parseCurrency("20 usd in usd") == nil)
        #expect(Calculator.parseCurrency("5 km in miles") == nil)
    }

    // MARK: Time zones

    @Test func nowInLondon() {
        let r = Calculator.evaluate("now in london", now: Self.now, timeZone: Self.la)
        #expect(r?.kind == .timeZone)
        #expect(r?.answer.hasPrefix("6:00 PM London") == true)   // 10:00 PDT = 18:00 BST
    }
    @Test func pstToTokyo() {
        let r = Calculator.evaluate("5pm pst in tokyo", now: Self.now, timeZone: Self.la)
        #expect(r?.answer.hasPrefix("9:00 AM Tokyo") == true)
        #expect(r?.answer.contains("Sun, Sep 20") == true)        // crosses midnight
        #expect(r?.expression == "5:00 PM PST → Tokyo")
    }
    @Test func unknownZoneIsNil() { #expect(Calculator.evaluate("5pm pst in narnia", now: Self.now, timeZone: Self.la) == nil) }

    // MARK: Dates

    @Test func daysUntil() {
        let r = Calculator.evaluate("days until dec 25", now: Self.now, timeZone: Self.la)
        #expect(r?.answer == "97 days")
        #expect(r?.expression == "Until Fri, Dec 25, 2026")
    }
    @Test func daysUntilPastDateRollsToNextYear() {
        #expect(Calculator.evaluate("days until jan 1", now: Self.now, timeZone: Self.la)?.answer == "104 days")
    }
    @Test func weeksFromToday() {
        let r = Calculator.evaluate("3 weeks from today", now: Self.now, timeZone: Self.la)
        #expect(r?.answer == "Sat, Oct 10, 2026")
    }
    @Test func daysAgo() { #expect(Calculator.evaluate("10 days ago", now: Self.now, timeZone: Self.la)?.answer == "Wed, Sep 9, 2026") }
    @Test func daysSince() { #expect(Calculator.evaluate("days since 2026-01-01", now: Self.now, timeZone: Self.la)?.answer == "261 days") }
}
