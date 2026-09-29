import Foundation

/// A stretch of time someone is busy (or the slot being booked).
struct ScheduleInterval: Equatable, Sendable {
    var start: Date
    var end: Date

    func overlaps(_ s: Date, _ e: Date) -> Bool { start < e && s < end }
}

/// Pure slot maths for the scheduler card: the hours the timeline shows, when
/// everyone is free, which few times to suggest, and whether a slot clashes.
enum SchedulePlanner {
    static let dayStartHour = 9
    static let dayEndHour = 18

    /// The timeline's hours: 9–18, stretched to show a typed time outside them.
    static func window(for day: Date, time: ScheduleRequest.ClockTime?, duration: Int, calendar cal: Calendar) -> ScheduleInterval {
        var startHour = dayStartHour
        var endHour = dayEndHour
        if let time {
            startHour = min(startHour, time.hour)
            endHour = max(endHour, Int((Double(time.minutes + duration) / 60).rounded(.up)))
        }
        endHour = min(endHour, 24)
        let start = cal.date(byAdding: .hour, value: startHour, to: day) ?? day
        let end = cal.date(byAdding: .hour, value: endHour, to: day) ?? day
        return ScheduleInterval(start: start, end: end)
    }

    /// The part of the day to look in first: "tomorrow morning", or lunchtime for lunch.
    static func preferredWindow(for day: Date, partOfDay: ScheduleRequest.PartOfDay?, activity: String, calendar cal: Calendar) -> ScheduleInterval? {
        let range: (start: Int, end: Int)
        if let partOfDay {
            range = partOfDay.range
        } else if activity == "Lunch" {
            range = (12 * 60, 14 * 60)
        } else if activity == "Breakfast" {
            range = (8 * 60, 10 * 60)
        } else if activity == "Dinner" || activity == "Drinks" {
            range = (18 * 60, 21 * 60)
        } else {
            return nil
        }
        guard let s = cal.date(byAdding: .minute, value: range.start, to: day),
              let e = cal.date(byAdding: .minute, value: range.end, to: day) else { return nil }
        return ScheduleInterval(start: s, end: e)
    }

    /// Starts on a `step`-minute grid inside the window where nobody who can
    /// be seen is busy for the whole `duration`.
    static func freeStarts(in window: ScheduleInterval, busy: [ScheduleInterval], duration: Int,
                           notBefore: Date, step: Int = 30) -> [Date] {
        let length = TimeInterval(duration * 60)
        let stride = TimeInterval(max(step, 5) * 60)
        var out: [Date] = []
        var t = window.start
        while t.addingTimeInterval(length) <= window.end {
            let end = t.addingTimeInterval(length)
            if t >= notBefore, !busy.contains(where: { $0.overlaps(t, end) }) { out.append(t) }
            t = t.addingTimeInterval(stride)
        }
        return out
    }

    /// Up to `limit` free starts, spread at least an hour (or one meeting)
    /// apart — inside the preferred part of the day when there is room there.
    static func suggestions(from free: [Date], duration: Int, preferred: ScheduleInterval?, limit: Int = 3) -> [Date] {
        let gap = TimeInterval(max(duration, 60) * 60)
        func spread(_ starts: [Date]) -> [Date] {
            var out: [Date] = []
            for t in starts where out.count < limit {
                if let last = out.last, t.timeIntervalSince(last) < gap { continue }
                out.append(t)
            }
            return out
        }
        if let preferred {
            let inside = spread(free.filter { $0 >= preferred.start && $0 < preferred.end })
            if !inside.isEmpty { return inside }
        }
        return spread(free)
    }

    /// Where the slot sits before the user picks one: the typed time, else the first suggestion.
    static func initialStart(time: ScheduleRequest.ClockTime?, day: Date, suggestions: [Date], calendar cal: Calendar) -> Date? {
        if let time { return cal.date(byAdding: .minute, value: time.minutes, to: day) }
        return suggestions.first
    }

    static func conflicts(start: Date, duration: Int, busy: [ScheduleInterval]) -> Bool {
        let end = start.addingTimeInterval(TimeInterval(duration * 60))
        return busy.contains { $0.overlaps(start, end) }
    }

    /// A time picked on the timeline, snapped to `step` minutes and kept inside the window.
    static func snap(_ date: Date, in window: ScheduleInterval, duration: Int, step: Int = 15) -> Date {
        let stepSeconds = TimeInterval(step * 60)
        let latest = max(0, window.end.timeIntervalSince(window.start) - TimeInterval(duration * 60))
        let offset = (date.timeIntervalSince(window.start) / stepSeconds).rounded() * stepSeconds
        return window.start.addingTimeInterval(min(max(0, offset), latest))
    }

    /// `now` rounded up to the next `step` minutes: nothing is suggested in the past.
    static func notBefore(_ now: Date, step: Int = 15) -> Date {
        let s = TimeInterval(step * 60)
        return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / s).rounded(.up) * s)
    }

    /// "30 min", "1 h", "1 h 15 min".
    static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The ± buttons: 15-minute steps up to an hour, then half hours; 15 min to 8 h.
    static func adjustedDuration(_ minutes: Int, by direction: Int) -> Int {
        let step = (direction > 0 ? minutes >= 60 : minutes > 60) ? 30 : 15
        return min(480, max(15, minutes + direction.signum() * step))
    }
}
