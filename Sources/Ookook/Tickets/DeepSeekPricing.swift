import Foundation

/// DeepSeek's peak/off-peak billing schedule, and its translation onto the
/// local clock.
///
/// From https://api-docs.deepseek.com/quick_start/pricing:
///
/// > Off-peak rates are half of the peak rates. Peak hours are 01:00 - 04:00
/// > and 06:00 - 10:00 UTC, Monday through Friday, excluding Chinese public
/// > holidays. All other hours are off-peak, including weekends and Chinese
/// > public holidays in full.
///
/// Both windows sit inside a single UTC date, and that date is the same in
/// China (UTC+8), so the weekday and holiday tests are done on the UTC date.
/// Only the display is translated; whether an instant is peak does not depend
/// on where this Mac is.
enum DeepSeekPricing {
    /// Half-open windows, as UTC hours.
    static let peakWindowsUTC: [(startHour: Int, endHour: Int)] = [(1, 4), (6, 10)]

    static let pricingURL = URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!

    /// Where the clock is now, and when it flips.
    struct BillingWindow {
        let isPeak: Bool
        /// The end of the current peak, or the start of the next one.
        let changesAt: Date?
    }

    static func state(at date: Date) -> BillingWindow {
        if let end = peakInterval(containing: date)?.end {
            return BillingWindow(isPeak: true, changesAt: end)
        }
        return BillingWindow(isPeak: false, changesAt: nextPeakStart(after: date))
    }

    static func isPeak(_ date: Date) -> Bool {
        guard isPeakDay(date) else { return false }
        let hour = utcCalendar.component(.hour, from: date)
        return peakWindowsUTC.contains { hour >= $0.startHour && hour < $0.endHour }
    }

    // MARK: Peak intervals

    private static func peakInterval(containing date: Date) -> DateInterval? {
        guard isPeak(date) else { return nil }
        let day = utcCalendar.startOfDay(for: date)
        let hour = utcCalendar.component(.hour, from: date)
        guard let window = peakWindowsUTC.first(where: { hour >= $0.startHour && hour < $0.endHour }) else { return nil }
        return DateInterval(start: day.addingTimeInterval(Double(window.startHour) * 3600),
                            end: day.addingTimeInterval(Double(window.endHour) * 3600))
    }

    /// The next window start strictly after `date`, scanning far enough ahead
    /// to clear the longest holiday stretch (Spring Festival plus a weekend).
    static func nextPeakStart(after date: Date) -> Date? {
        var day = utcCalendar.startOfDay(for: date)
        for _ in 0 ..< 20 {
            if isPeakDay(day) {
                for window in peakWindowsUTC {
                    let start = day.addingTimeInterval(Double(window.startHour) * 3600)
                    if start > date { return start }
                }
            }
            guard let next = utcCalendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// A UTC calendar day that can hold peak hours: a weekday that is not a
    /// Chinese public holiday.
    private static func isPeakDay(_ day: Date) -> Bool {
        isWeekday(day) && holidayName(on: day) == nil
    }

    private static func isWeekday(_ day: Date) -> Bool {
        (2 ... 6).contains(utcCalendar.component(.weekday, from: day)) // 1 = Sunday
    }

    // MARK: Local-time translation

    /// The recurring schedule on the local clock, e.g.
    /// "Mon–Fri 04:00–07:00, 09:00–13:00" in Europe/Istanbul.
    ///
    /// Holidays are ignored on purpose: this describes the shape of the week,
    /// not one week's exceptions (those show up in the live state instead).
    /// Days that share a set of ranges are grouped, so a timezone where the
    /// UTC weekday lands on the previous local day still reads correctly.
    static func localWeeklyPattern(around date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Monday of the local week containing `date`.
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        let monday = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: date)!)

        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var days: [(name: String, ranges: [String])] = []
        for offset in 0 ..< 7 {
            let start = calendar.date(byAdding: .day, value: offset, to: monday)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            days.append((names[offset], localRanges(in: DateInterval(start: start, end: end), timeZone: timeZone)))
        }

        var groups: [(names: [String], ranges: [String])] = []
        for day in days {
            if let last = groups.last, last.ranges == day.ranges {
                groups[groups.count - 1].names.append(day.name)
            } else {
                groups.append(([day.name], day.ranges))
            }
        }
        let withPeak = groups.filter { !$0.ranges.isEmpty }
        let shown = withPeak.isEmpty ? groups : withPeak
        return shown.map { group in
            let label = group.names.count == 1 ? group.names[0] : "\(group.names.first!)–\(group.names.last!)"
            return group.ranges.isEmpty ? "\(label) off-peak" : "\(label) \(group.ranges.joined(separator: ", "))"
        }.joined(separator: " · ")
    }

    /// Peak ranges that fall inside one local day, split at local midnight.
    private static func localRanges(in day: DateInterval, timeZone: TimeZone) -> [String] {
        var utcDay = utcCalendar.date(byAdding: .day, value: -1, to: utcCalendar.startOfDay(for: day.start))!
        var ranges: [String] = []
        while utcDay < day.end {
            // Weekdays only: this is the recurring shape of the week, without
            // the holiday exceptions the live state reports.
            if isWeekday(utcDay) {
                for window in peakWindowsUTC {
                    let start = max(utcDay.addingTimeInterval(Double(window.startHour) * 3600), day.start)
                    let end = min(utcDay.addingTimeInterval(Double(window.endHour) * 3600), day.end)
                    if start < end { ranges.append(rangeLabel(start, end, timeZone: timeZone)) }
                }
            }
            utcDay = utcCalendar.date(byAdding: .day, value: 1, to: utcDay)!
        }
        return ranges
    }

    private static func rangeLabel(_ start: Date, _ end: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func hhmm(_ date: Date) -> String {
            String(format: "%02d:%02d",
                   calendar.component(.hour, from: date),
                   calendar.component(.minute, from: date))
        }
        // A range clipped at local midnight reads better as 24:00.
        let endText = hhmm(end) == "00:00" ? "24:00" : hhmm(end)
        return "\(hhmm(start))–\(endText)"
    }

    // MARK: Display strings

    /// "Peak now — ends 13:00 (in 1h 36m)" / "Off-peak now — peak Thu 04:00 (in 17h)".
    static func statusText(at date: Date, timeZone: TimeZone = .current) -> String {
        let state = state(at: date)
        guard let change = state.changesAt else {
            return state.isPeak ? "Peak now" : "Off-peak now"
        }
        let when = transitionLabel(change, from: date, timeZone: timeZone)
        let countdown = countdown(from: date, to: change)
        return state.isPeak
            ? "Peak now — ends \(when) (in \(countdown))"
            : "Off-peak now — peak \(when) (in \(countdown))"
    }

    /// One line for the sidebar tooltip.
    static func shortStatus(at date: Date, timeZone: TimeZone = .current) -> String {
        let state = state(at: date)
        guard let change = state.changesAt else {
            return state.isPeak ? "DeepSeek: peak rates" : "DeepSeek: off-peak"
        }
        return state.isPeak
            ? "DeepSeek: peak rates until \(transitionLabel(change, from: date, timeZone: timeZone))"
            : "DeepSeek: off-peak, peak \(transitionLabel(change, from: date, timeZone: timeZone))"
    }

    /// The full explanation for a tooltip.
    static func detail(at date: Date, timeZone: TimeZone = .current) -> String {
        var lines = [
            "Peak hours are 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding Chinese public holidays; everything else is off-peak at half price.",
            "In \(timeZone.identifier): \(localWeeklyPattern(around: date, timeZone: timeZone)).",
            statusText(at: date, timeZone: timeZone) + ".",
        ]
        if let holiday = holidayName(on: date) {
            lines.append("Today is \(holiday) in China — off-peak all day.")
        } else if !holidayCalendarIsKnown(for: date) {
            lines.append("The Chinese holiday calendar for \(utcCalendar.component(.year, from: date)) is not published yet; weekdays are assumed to be peak.")
        }
        return lines.joined(separator: "\n")
    }

    /// "13:00", "tomorrow 04:00" or "Thu 04:00", whichever is clearest.
    static func transitionLabel(_ date: Date, from now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            formatter.dateFormat = "'tomorrow' HH:mm"
        } else {
            formatter.dateFormat = "EEE HH:mm"
        }
        return formatter.string(from: date)
    }

    static func countdown(from now: Date, to date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainder = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(remainder)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    // MARK: Chinese holidays

    /// Days off from the State Council's yearly notice (2026: 国办发明电〔2025〕7号,
    /// published 2025-11-04). Make-up working weekends are deliberately left
    /// out: they fall on Saturdays and Sundays, which are off-peak regardless.
    ///
    /// The notice for the next year lands in November; a year with no table
    /// falls back to the plain weekday rule.
    private static let holidays: [Int: [Int: String]] = [
        2026: [
            20260101: "New Year's Day",
            20260102: "New Year holiday",
            20260103: "New Year holiday",
            20260215: "Spring Festival",
            20260216: "Spring Festival",
            20260217: "Spring Festival",
            20260218: "Spring Festival",
            20260219: "Spring Festival",
            20260220: "Spring Festival",
            20260221: "Spring Festival",
            20260222: "Spring Festival",
            20260223: "Spring Festival",
            20260404: "Qingming Festival",
            20260405: "Qingming Festival",
            20260406: "Qingming Festival",
            20260501: "Labour Day",
            20260502: "Labour Day",
            20260503: "Labour Day",
            20260504: "Labour Day",
            20260505: "Labour Day",
            20260619: "Dragon Boat Festival",
            20260620: "Dragon Boat Festival",
            20260621: "Dragon Boat Festival",
            20260925: "Mid-Autumn Festival",
            20260926: "Mid-Autumn Festival",
            20260927: "Mid-Autumn Festival",
            20261001: "National Day",
            20261002: "National Day",
            20261003: "National Day",
            20261004: "National Day",
            20261005: "National Day",
            20261006: "National Day",
            20261007: "National Day",
        ],
    ]

    /// The holiday this UTC date falls on, if any.
    static func holidayName(on date: Date) -> String? {
        let year = utcCalendar.component(.year, from: date)
        let month = utcCalendar.component(.month, from: date)
        let day = utcCalendar.component(.day, from: date)
        return holidays[year]?[year * 10000 + month * 100 + day]
    }

    static func holidayCalendarIsKnown(for date: Date) -> Bool {
        holidays[utcCalendar.component(.year, from: date)] != nil
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}
