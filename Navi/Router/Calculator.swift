import Foundation
import AppKit

/// A computed answer for a query: arithmetic, unit / currency conversion,
/// time-zone conversion or date math.
struct CalcResult: Equatable, Sendable {
    enum Kind: String, Sendable { case arithmetic, unit, currency, timeZone, date }
    let answer: String        // formatted, what the row shows as title
    let expression: String    // normalized expression shown as subtitle
    let kind: Kind
}

/// Instant math. All parsing is pure so it can be unit-tested; `results(for:)`
/// wraps the result in a `.calculation` row whose ⏎ copies the answer.
enum Calculator {

    // MARK: - Entry points

    /// Synchronous evaluation (no network). Returns nil if the query isn't math.
    static func evaluate(_ query: String, now: Date = Date(), timeZone: TimeZone = .current) -> CalcResult? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count < 200 else { return nil }
        if let r = evaluateArithmetic(q) { return r }
        if let r = convertUnits(q) { return r }
        if let r = convertTimeZone(q, now: now, from: timeZone) { return r }
        if let r = dateMath(q, now: now, timeZone: timeZone) { return r }
        return nil
    }

    static func results(for query: String) -> [SearchResult] {
        guard let r = evaluate(query) else { return [] }
        return [result(r)]
    }

    static func result(_ r: CalcResult) -> SearchResult {
        let icon: String
        switch r.kind {
        case .arithmetic: icon = "equal.circle"
        case .unit: icon = "ruler"
        case .currency: icon = "dollarsign.circle"
        case .timeZone: icon = "clock"
        case .date: icon = "calendar"
        }
        let answer = r.answer
        return SearchResult(id: "calc:\(r.expression)", kind: .calculation, title: answer, subtitle: r.expression,
                            icon: .system(icon), score: 0.97, shortcutHint: "⏎ Copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(answer, forType: .string)
            return .keepOpen
        }
    }

    // MARK: - Arithmetic

    static let functionNames = ["sqrt", "ln", "log", "exp", "abs", "floor", "ceil", "ceiling", "trunc", "round"]

    /// Rewrites human input ("12x34", "15 + 20%", "2^10", "12% of 340") into a
    /// plain expression for `ExpressionParser`, or nil.
    static func sanitizeArithmetic(_ input: String) -> String? {
        var s = input.lowercased()
        for p in ["what is ", "what's ", "whats ", "calc ", "calculate ", "="] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        while s.hasSuffix("=") || s.hasSuffix("?") { s = String(s.dropLast()) }
        s = s.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "^", with: "**")
            .replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: " plus ", with: " + ")
            .replacingOccurrences(of: " minus ", with: " - ")
            .replacingOccurrences(of: " times ", with: " * ")
            .replacingOccurrences(of: " divided by ", with: " / ")
            .replacingOccurrences(of: " over ", with: " / ")
            .replacingOccurrences(of: " mod ", with: " % ")
            .replacingOccurrences(of: "percent", with: "%")
        // "x" as multiplication when between numbers/parens (not part of a word)
        s = regexReplace(s, #"(?<=[\d\)\s])x(?=[\d\(\s])"#, with: "*")
        // "N% of M" → (M*N/100)
        s = regexReplace(s, #"(\d+(?:\.\d+)?)\s*%\s*of\s*(\d+(?:\.\d+)?)"#, with: "($2*$1/100)")
        // "A + N%" / "A - N%" → A*(1±N/100)
        s = regexReplace(s, #"(\d+(?:\.\d+)?)\s*\+\s*(\d+(?:\.\d+)?)\s*%"#, with: "($1*(1+$2/100))")
        s = regexReplace(s, #"(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*%"#, with: "($1*(1-$2/100))")
        // Remaining "N%" (not followed by a number, which would be modulo) → (N/100)
        s = regexReplace(s, #"(\d+(?:\.\d+)?)\s*%(?!\s*\d)"#, with: "($1/100)")
        s = regexReplace(s, #"\bpi\b"#, with: "3.141592653589793")
        s = regexReplace(s, #"(?<![a-z0-9.])e(?![a-z0-9])"#, with: "2.718281828459045")
        s = s.replacingOccurrences(of: " ", with: "")
        return s.isEmpty ? nil : s
    }

    static func evaluateArithmetic(_ query: String) -> CalcResult? {
        guard query.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        guard let s = sanitizeArithmetic(query) else { return nil }
        var parser = ExpressionParser(s)
        guard let value = parser.evaluate(), value.isFinite else { return nil }
        let display = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalcResult(answer: formatNumber(value), expression: display, kind: .arithmetic)
    }

    /// Tiny recursive-descent evaluator: + - * / % ** unary minus, parens, functions.
    /// Never traps; returns nil for anything it doesn't understand. Requires at
    /// least one operator or function so bare numbers ("2024") aren't "math".
    struct ExpressionParser {
        private let chars: [Character]
        private var pos = 0
        private var sawOperation = false

        init(_ s: String) { chars = Array(s) }

        mutating func evaluate() -> Double? {
            guard let v = parseExpr(), pos == chars.count, sawOperation else { return nil }
            return v
        }

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        private mutating func advance() { pos += 1 }

        private mutating func parseExpr() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                advance(); sawOperation = true
                guard let rhs = parseTerm() else { return nil }
                lhs = c == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        private mutating func parseTerm() -> Double? {
            guard var lhs = parseFactor() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                if c == "*", pos + 1 < chars.count, chars[pos + 1] == "*" { break }   // power handled in factor
                advance(); sawOperation = true
                guard let rhs = parseFactor() else { return nil }
                switch c {
                case "*": lhs *= rhs
                case "/": guard rhs != 0 else { return nil }; lhs /= rhs
                default: guard rhs != 0 else { return nil }; lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        private mutating func parseFactor() -> Double? {
            guard let base = parseUnary() else { return nil }
            if peek() == "*", pos + 1 < chars.count, chars[pos + 1] == "*" {
                pos += 2; sawOperation = true
                guard let exp = parseFactor() else { return nil }   // right-assoc
                return pow(base, exp)
            }
            return base
        }

        private mutating func parseUnary() -> Double? {
            if peek() == "-" { advance(); return parseUnary().map { -$0 } }
            if peek() == "+" { advance(); return parseUnary() }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                advance()
                guard let v = parseExpr(), peek() == ")" else { return nil }
                advance(); return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while let d = peek(), d.isNumber || d == "." { s.append(d); advance() }
                return Double(s)
            }
            if c.isLetter {
                var name = ""
                while let d = peek(), d.isLetter { name.append(d); advance() }
                guard Calculator.functionNames.contains(name), peek() == "(" else { return nil }
                advance()
                guard let arg = parseExpr(), peek() == ")" else { return nil }
                advance(); sawOperation = true
                switch name {
                case "sqrt": return arg < 0 ? nil : arg.squareRoot()
                case "ln": return arg <= 0 ? nil : Foundation.log(arg)
                case "log": return arg <= 0 ? nil : log10(arg)
                case "exp": return Foundation.exp(arg)
                case "abs": return abs(arg)
                case "floor": return arg.rounded(.down)
                case "ceil", "ceiling": return arg.rounded(.up)
                case "trunc": return arg.rounded(.towardZero)
                case "round": return arg.rounded()
                default: return nil
                }
            }
            return nil
        }
    }

    static func formatNumber(_ v: Double, maxFraction: Int = 6) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = maxFraction
        f.minimumFractionDigits = 0
        if abs(v) >= 1e15 || (abs(v) < 1e-6 && v != 0) {
            f.numberStyle = .scientific
            f.maximumFractionDigits = 4
        }
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // MARK: - Units

    struct UnitSpec: Sendable {
        let unit: Dimension
        let name: String
    }

    static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86400))
    static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604800))
    static let cup = UnitVolume.cups

    static let units: [String: Dimension] = {
        var m: [String: Dimension] = [:]
        func reg(_ names: [String], _ u: Dimension) { for n in names { m[n] = u } }
        // Length
        reg(["km", "kilometer", "kilometers", "kilometre", "kilometres"], UnitLength.kilometers)
        reg(["m", "meter", "meters", "metre", "metres"], UnitLength.meters)
        reg(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], UnitLength.centimeters)
        reg(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], UnitLength.millimeters)
        reg(["mi", "mile", "miles"], UnitLength.miles)
        reg(["ft", "feet", "foot", "'"], UnitLength.feet)
        reg(["in", "inch", "inches", "\""], UnitLength.inches)
        reg(["yd", "yard", "yards"], UnitLength.yards)
        reg(["nmi", "nautical mile", "nautical miles"], UnitLength.nauticalMiles)
        // Mass
        reg(["kg", "kilo", "kilos", "kilogram", "kilograms"], UnitMass.kilograms)
        reg(["g", "gram", "grams"], UnitMass.grams)
        reg(["mg", "milligram", "milligrams"], UnitMass.milligrams)
        reg(["lb", "lbs", "pound", "pounds"], UnitMass.pounds)
        reg(["oz", "ounce", "ounces"], UnitMass.ounces)
        reg(["st", "stone", "stones"], UnitMass.stones)
        reg(["t", "ton", "tons", "tonne", "tonnes"], UnitMass.metricTons)
        // Temperature
        reg(["c", "°c", "celsius", "centigrade", "degrees c", "degrees celsius"], UnitTemperature.celsius)
        reg(["f", "°f", "fahrenheit", "degrees f", "degrees fahrenheit"], UnitTemperature.fahrenheit)
        reg(["k", "kelvin"], UnitTemperature.kelvin)
        // Volume
        reg(["l", "liter", "liters", "litre", "litres"], UnitVolume.liters)
        reg(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], UnitVolume.milliliters)
        reg(["gal", "gallon", "gallons"], UnitVolume.gallons)
        reg(["qt", "quart", "quarts"], UnitVolume.quarts)
        reg(["pt", "pint", "pints"], UnitVolume.pints)
        reg(["cup", "cups"], UnitVolume.cups)
        reg(["tbsp", "tablespoon", "tablespoons"], UnitVolume.tablespoons)
        reg(["tsp", "teaspoon", "teaspoons"], UnitVolume.teaspoons)
        reg(["floz", "fl oz", "fluid ounce", "fluid ounces"], UnitVolume.fluidOunces)
        // Speed
        reg(["kph", "kmh", "km/h", "kmph"], UnitSpeed.kilometersPerHour)
        reg(["mph", "mi/h"], UnitSpeed.milesPerHour)
        reg(["m/s", "mps"], UnitSpeed.metersPerSecond)
        reg(["knot", "knots", "kn"], UnitSpeed.knots)
        // Area
        reg(["sqft", "sq ft", "square feet", "square foot"], UnitArea.squareFeet)
        reg(["sqm", "sq m", "m2", "square meters", "square metres"], UnitArea.squareMeters)
        reg(["acre", "acres"], UnitArea.acres)
        reg(["hectare", "hectares", "ha"], UnitArea.hectares)
        reg(["km2", "sq km", "square kilometers"], UnitArea.squareKilometers)
        reg(["sqmi", "sq mi", "square miles"], UnitArea.squareMiles)
        // Data
        reg(["b", "byte", "bytes"], UnitInformationStorage.bytes)
        reg(["kb", "kilobyte", "kilobytes"], UnitInformationStorage.kilobytes)
        reg(["mb", "megabyte", "megabytes"], UnitInformationStorage.megabytes)
        reg(["gb", "gigabyte", "gigabytes"], UnitInformationStorage.gigabytes)
        reg(["tb", "terabyte", "terabytes"], UnitInformationStorage.terabytes)
        reg(["gib"], UnitInformationStorage.gibibytes)
        reg(["mib"], UnitInformationStorage.mebibytes)
        // Time
        reg(["ms", "millisecond", "milliseconds"], UnitDuration.milliseconds)
        reg(["s", "sec", "secs", "second", "seconds"], UnitDuration.seconds)
        reg(["min", "mins", "minute", "minutes"], UnitDuration.minutes)
        reg(["h", "hr", "hrs", "hour", "hours"], UnitDuration.hours)
        reg(["day", "days"], day)
        reg(["wk", "week", "weeks"], week)
        // Energy
        reg(["j", "joule", "joules"], UnitEnergy.joules)
        reg(["kj", "kilojoule", "kilojoules"], UnitEnergy.kilojoules)
        reg(["cal", "calorie", "calories"], UnitEnergy.calories)
        reg(["kcal", "kilocalorie", "kilocalories"], UnitEnergy.kilocalories)
        reg(["kwh"], UnitEnergy.kilowattHours)
        // Angle
        reg(["deg", "degree", "degrees"], UnitAngle.degrees)
        reg(["rad", "radian", "radians"], UnitAngle.radians)
        // Pressure
        reg(["psi"], UnitPressure.poundsForcePerSquareInch)
        reg(["bar"], UnitPressure.bars)
        reg(["kpa"], UnitPressure.kilopascals)
        reg(["atm"], UnitPressure(symbol: "atm", converter: UnitConverterLinear(coefficient: 101325)))
        return m
    }()

    static let unitRegex = try! NSRegularExpression(
        pattern: #"^(-?\d+(?:\.\d+)?)\s*([a-z°'"/ ]+?)\s+(?:in|to|into|as)\s+([a-z°'"/ ]+?)\s*$"#)

    static func convertUnits(_ query: String) -> CalcResult? {
        let q = query.lowercased().replacingOccurrences(of: ",", with: "")
        guard let m = unitRegex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let value = Double(q[Range(m.range(at: 1), in: q)!]) else { return nil }
        let fromName = String(q[Range(m.range(at: 2), in: q)!]).trimmingCharacters(in: .whitespaces)
        let toName = String(q[Range(m.range(at: 3), in: q)!]).trimmingCharacters(in: .whitespaces)
        guard let from = units[fromName], let to = units[toName],
              type(of: from) == type(of: to) else { return nil }
        let measurement = Measurement(value: value, unit: from)
        let converted = measurement.converted(to: to)
        let answer = "\(formatNumber(converted.value, maxFraction: 4)) \(to.symbol)"
        let expr = "\(formatNumber(value, maxFraction: 4)) \(from.symbol) → \(to.symbol)"
        return CalcResult(answer: answer, expression: expr, kind: .unit)
    }

    // MARK: - Currency (async)

    static let currencyCodes: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "INR", "MXN", "BRL", "KRW", "SEK", "NOK",
        "DKK", "PLN", "NZD", "SGD", "HKD", "ZAR", "TRY", "CZK", "HUF", "ILS", "THB", "IDR", "MYR", "PHP",
        "RON", "BGN", "ISK",
    ]
    static let currencySymbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW"]
    static let currencyWords: [String: String] = [
        "dollars": "USD", "dollar": "USD", "bucks": "USD", "euros": "EUR", "euro": "EUR", "pounds": "GBP",
        "quid": "GBP", "yen": "JPY", "rupees": "INR", "rupee": "INR", "won": "KRW", "pesos": "MXN", "francs": "CHF",
        "yuan": "CNY", "rmb": "CNY", "loonies": "CAD",
    ]

    struct CurrencyRequest: Equatable, Sendable { let amount: Double; let from: String; let to: String }

    static let currencyRegex = try! NSRegularExpression(
        pattern: #"^([$€£¥₹₩]?)\s*(\d+(?:\.\d+)?)\s*([a-z]{3,7}|[$€£¥₹₩])?\s+(?:in|to|into|as)\s+([a-z]{3,7}|[$€£¥₹₩])\s*$"#)

    static func parseCurrency(_ query: String) -> CurrencyRequest? {
        let q = query.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let m = currencyRegex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) else { return nil }
        func g(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: q) else { return nil }
            let s = String(q[r]); return s.isEmpty ? nil : s
        }
        guard let amount = Double(g(2) ?? "") else { return nil }
        func code(_ s: String?) -> String? {
            guard let s else { return nil }
            if let sym = currencySymbols[s] { return sym }
            if let w = currencyWords[s] { return w }
            let up = s.uppercased()
            return currencyCodes.contains(up) ? up : nil
        }
        guard let from = code(g(1)) ?? code(g(3)), let to = code(g(4)), from != to else { return nil }
        return CurrencyRequest(amount: amount, from: from, to: to)
    }

    /// Fetches a live rate from frankfurter.app. Network; call from `results(for:decision:)`.
    static func convertCurrency(_ req: CurrencyRequest) async throws -> CalcResult {
        var comps = URLComponents(string: "https://api.frankfurter.app/latest")!
        comps.queryItems = [.init(name: "amount", value: String(req.amount)),
                            .init(name: "from", value: req.from), .init(name: "to", value: req.to)]
        var r = URLRequest(url: comps.url!)
        r.timeoutInterval = 4
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NaviError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Any],
              let v = (rates[req.to] as? NSNumber)?.doubleValue else {
            throw NaviError.decoding("frankfurter response")
        }
        let answer = "\(formatNumber(v, maxFraction: 2)) \(req.to)"
        let expr = "\(formatNumber(req.amount, maxFraction: 2)) \(req.from) → \(req.to)"
        return CalcResult(answer: answer, expression: expr, kind: .currency)
    }

    // MARK: - Time zones

    static let zoneNames: [String: String] = [
        "utc": "UTC", "gmt": "GMT", "z": "UTC",
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "mst": "America/Denver", "mdt": "America/Denver", "mt": "America/Denver", "mountain": "America/Denver",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "central": "America/Chicago",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "eastern": "America/New_York",
        "bst": "Europe/London", "cet": "Europe/Paris", "cest": "Europe/Paris", "eet": "Europe/Athens",
        "ist": "Asia/Kolkata", "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "hkt": "Asia/Hong_Kong", "sgt": "Asia/Singapore",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "nzst": "Pacific/Auckland", "hst": "Pacific/Honolulu",
        "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "sf": "America/Los_Angeles", "seattle": "America/Los_Angeles", "portland": "America/Los_Angeles",
        "vancouver": "America/Vancouver", "denver": "America/Denver", "phoenix": "America/Phoenix",
        "chicago": "America/Chicago", "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "new york": "America/New_York", "nyc": "America/New_York", "ny": "America/New_York", "boston": "America/New_York",
        "miami": "America/New_York", "toronto": "America/Toronto", "atlanta": "America/New_York", "dc": "America/New_York",
        "washington": "America/New_York", "mexico city": "America/Mexico_City", "sao paulo": "America/Sao_Paulo",
        "buenos aires": "America/Argentina/Buenos_Aires", "honolulu": "Pacific/Honolulu", "hawaii": "Pacific/Honolulu",
        "anchorage": "America/Anchorage", "london": "Europe/London", "dublin": "Europe/Dublin", "lisbon": "Europe/Lisbon",
        "paris": "Europe/Paris", "berlin": "Europe/Berlin", "madrid": "Europe/Madrid", "rome": "Europe/Rome",
        "amsterdam": "Europe/Amsterdam", "zurich": "Europe/Zurich", "stockholm": "Europe/Stockholm", "oslo": "Europe/Oslo",
        "copenhagen": "Europe/Copenhagen", "helsinki": "Europe/Helsinki", "warsaw": "Europe/Warsaw", "prague": "Europe/Prague",
        "vienna": "Europe/Vienna", "athens": "Europe/Athens", "istanbul": "Europe/Istanbul", "moscow": "Europe/Moscow",
        "dubai": "Asia/Dubai", "tel aviv": "Asia/Jerusalem", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "india": "Asia/Kolkata", "singapore": "Asia/Singapore", "hong kong": "Asia/Hong_Kong",
        "shanghai": "Asia/Shanghai", "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "taipei": "Asia/Taipei",
        "seoul": "Asia/Seoul", "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "bangkok": "Asia/Bangkok",
        "jakarta": "Asia/Jakarta", "manila": "Asia/Manila", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "brisbane": "Australia/Brisbane", "perth": "Australia/Perth", "auckland": "Pacific/Auckland",
        "cairo": "Africa/Cairo", "johannesburg": "Africa/Johannesburg", "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi",
    ]

    static func timeZone(named raw: String) -> (TimeZone, String)? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = zoneNames[name], let tz = TimeZone(identifier: id) { return (tz, prettyZoneName(name)) }
        if let tz = TimeZone(abbreviation: name.uppercased()) { return (tz, name.uppercased()) }
        if let tz = TimeZone(identifier: raw) { return (tz, raw) }
        return nil
    }

    static func prettyZoneName(_ n: String) -> String {
        if n.count <= 4 { return n.uppercased() }
        return n.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let tzNowRegex = try! NSRegularExpression(
        pattern: #"^(?:what(?:'s| is)?\s+(?:the\s+)?)?(?:time|now|current time|local time)(?:\s+is\s+it)?\s+in\s+(.+?)\??$"#)
    static let tzConvertRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+([a-z .]+?)\s+(?:in|to|into|→)\s+([a-z .]+?)\??$"#)

    static func convertTimeZone(_ query: String, now: Date, from local: TimeZone) -> CalcResult? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let full = NSRange(q.startIndex..., in: q)
        if let m = tzNowRegex.firstMatch(in: q, range: full), let r = Range(m.range(at: 1), in: q),
           let z = timeZone(named: String(q[r])) {
            return CalcResult(answer: formatTime(now, in: z.0, zoneLabel: z.1),
                              expression: "Current time in \(z.1)", kind: .timeZone)
        }
        if let m = tzConvertRegex.firstMatch(in: q, range: full) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: q).map { String(q[$0]) } }
            guard var hour = Int(g(1) ?? ""), let fromZ = timeZone(named: g(4) ?? ""),
                  let toZ = timeZone(named: g(5) ?? "") else { return nil }
            let (fromTZ, fromName) = fromZ
            let (toTZ, toName) = toZ
            let minute = Int(g(2) ?? "") ?? 0
            if let ampm = g(3) {
                if ampm == "pm", hour < 12 { hour += 12 }
                if ampm == "am", hour == 12 { hour = 0 }
            }
            guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = fromTZ
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour; comps.minute = minute
            guard let src = cal.date(from: comps) else { return nil }
            let srcLabel = formatTime(src, in: fromTZ, zoneLabel: fromName, dayIfDifferent: false)
            return CalcResult(answer: formatTime(src, in: toTZ, zoneLabel: toName, relativeTo: src, in: fromTZ),
                              expression: "\(srcLabel) → \(toName)", kind: .timeZone)
        }
        return nil
    }

    static func formatTime(_ date: Date, in tz: TimeZone, zoneLabel: String, dayIfDifferent: Bool = true,
                           relativeTo ref: Date? = nil, in refTZ: TimeZone? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = tz
        f.dateFormat = "h:mm a"
        var s = "\(f.string(from: date)) \(zoneLabel)"
        if dayIfDifferent {
            var calTZ = Calendar(identifier: .gregorian); calTZ.timeZone = tz
            var calRef = Calendar(identifier: .gregorian); calRef.timeZone = refTZ ?? .current
            let d1 = calTZ.dateComponents([.year, .month, .day], from: date)
            let d2 = calRef.dateComponents([.year, .month, .day], from: ref ?? date)
            if d1 != d2 {
                let df = DateFormatter(); df.locale = f.locale; df.timeZone = tz; df.dateFormat = "EEE, MMM d"
                s += " (\(df.string(from: date)))"
            }
        }
        return s
    }

    // MARK: - Dates

    static let monthNames: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    static let namedDays: [String: (Int, Int)] = [
        "christmas": (12, 25), "xmas": (12, 25), "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1),
        "halloween": (10, 31), "valentines": (2, 14), "valentine's": (2, 14), "valentines day": (2, 14),
    ]

    /// Parses "dec 25", "december 25 2027", "25 dec", "12/25", "12/25/2026", "2026-12-25", "christmas".
    /// Dates without a year resolve to the next occurrence on or after `now`.
    static func parseDate(_ raw: String, now: Date, timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        if s == "today" { return today }
        if s == "tomorrow" { return cal.date(byAdding: .day, value: 1, to: today) }
        if s == "yesterday" { return cal.date(byAdding: .day, value: -1, to: today) }
        var month: Int?, dayN: Int?, year: Int?
        if let (m, d) = namedDays[s] { month = m; dayN = d }
        else if let m = s.range(of: #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#, options: .regularExpression) {
            let p = s[m].split(separator: "-").compactMap { Int($0) }; year = p[0]; month = p[1]; dayN = p[2]
        } else if s.range(of: #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#, options: .regularExpression) != nil {
            let p = s.split(separator: "/").compactMap { Int($0) }
            month = p[0]; dayN = p[1]
            if p.count == 3 { year = p[2] < 100 ? 2000 + p[2] : p[2] }
        } else {
            let parts = s.split(separator: " ").map(String.init)
            for p in parts {
                if let m = monthNames[p] { month = m }
                else if let n = Int(p) { if n > 31 { year = n } else if dayN == nil { dayN = n } else { year = n } }
                else if p != "of" && p != "the" { return nil }
            }
        }
        guard let month, let dayN, (1...12).contains(month), (1...31).contains(dayN) else { return nil }
        let thisYear = cal.component(.year, from: today)
        var comps = DateComponents(year: year ?? thisYear, month: month, day: dayN)
        guard var date = cal.date(from: comps) else { return nil }
        if year == nil, date < today {
            comps.year = thisYear + 1
            guard let next = cal.date(from: comps) else { return nil }
            date = next
        }
        return date
    }

    static let untilRegex = try! NSRegularExpression(pattern: #"^(?:how many\s+)?(days?|weeks?)\s+(until|till|til|to|since|from)\s+(.+?)\??$"#)
    static let offsetRegex = try! NSRegularExpression(
        pattern: #"^(?:what(?:'s| is)?\s+(?:the\s+date\s+)?)?(\d+)\s+(day|days|week|weeks|month|months|year|years)\s+(from|after|before|ago)(?:\s+(today|now|tomorrow|yesterday|.+?))?\??$"#)

    static func dateMath(_ query: String, now: Date, timeZone: TimeZone) -> CalcResult? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let full = NSRange(q.startIndex..., in: q)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.timeZone = timeZone; df.dateFormat = "EEE, MMM d, yyyy"

        if let m = untilRegex.firstMatch(in: q, range: full) {
            func g(_ i: Int) -> String { Range(m.range(at: i), in: q).map { String(q[$0]) } ?? "" }
            let unit = g(1), rel = g(2)
            guard let target = parseDate(g(3), now: now, timeZone: timeZone) else { return nil }
            let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
            let n = abs(days)
            let value: String
            if unit.hasPrefix("week") {
                value = "\(formatNumber(Double(n) / 7, maxFraction: 1)) week\(n == 7 ? "" : "s")"
            } else {
                value = "\(n) day\(n == 1 ? "" : "s")"
            }
            let label = (rel == "since" || days < 0) ? "since" : "until"
            return CalcResult(answer: value, expression: "\(label.capitalized) \(df.string(from: target))", kind: .date)
        }
        if let m = offsetRegex.firstMatch(in: q, range: full) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: q).map { String(q[$0]) } }
            guard let n = Int(g(1) ?? ""), let unit = g(2), let dir = g(3) else { return nil }
            let baseRaw = g(4) ?? "today"
            guard let base = parseDate(baseRaw, now: now, timeZone: timeZone) else { return nil }
            let comp: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear
                : unit.hasPrefix("month") ? .month : .year
            let sign = (dir == "before" || dir == "ago") ? -1 : 1
            guard let result = cal.date(byAdding: comp, value: sign * n, to: base) else { return nil }
            return CalcResult(answer: df.string(from: result), expression: "\(n) \(unit) \(dir) \(baseRaw)", kind: .date)
        }
        return nil
    }

    // MARK: - Helpers

    static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
