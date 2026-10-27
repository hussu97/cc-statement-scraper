import Foundation
import Synchronization

/// Business dates are calendar dates in Asia/Dubai (`public.dubai_date()`), and
/// every formatter pins `en_US_POSIX` so an Arabic-locale phone still renders
/// ASCII digits and Gregorian months.
public enum LedgerDates {
    public static let timeZone = TimeZone(identifier: "Asia/Dubai")!
    public static let locale = Locale(identifier: "en_US_POSIX")

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = locale
        return c
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    // DateFormatter is Sendable (thread-safe for formatting); these are never
    // mutated after creation.
    private static let dayMonth = formatter("d MMM")
    private static let dayMonthYear = formatter("d MMM yyyy")
    private static let monthYear = formatter("MMMM yyyy")
    private static let shortMonthYearFormat = formatter("MMM yyyy")
    private static let shortMonth = formatter("MMM")
    private static let fullMonth = formatter("MMMM")
    private static let time = formatter("HH:mm")
    private static let dayTime = formatter("d MMM yyyy, HH:mm")

    /// Today's business date.
    public static func today(now: Date = .now) -> CalendarDay {
        CalendarDay(date: now)
    }

    /// `"8 Oct"`, or `"8 Oct 2025"` when not in the current year.
    public static func dayLabel(_ day: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        (day.year == today.year ? dayMonth : dayMonthYear).string(from: day.startDate)
    }

    /// `"8 Oct 2026"`: always with the year (statement periods, timeline headers).
    public static func fullDayLabel(_ day: CalendarDay) -> String { dayMonthYear.string(from: day.startDate) }

    /// `"Today"`, `"Yesterday"`, else `dayLabel`. Used as Activity section headers.
    public static func relativeDayLabel(_ day: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: -1) { return "Yesterday" }
        return dayLabel(day, today: today)
    }

    /// `"October 2026"`.
    public static func monthTitle(_ day: CalendarDay) -> String { monthYear.string(from: day.startDate) }

    /// `"Oct 2026"`.
    public static func shortMonthYear(_ day: CalendarDay) -> String { shortMonthYearFormat.string(from: day.startDate) }

    /// `"October"`.
    public static func monthName(_ day: CalendarDay) -> String { fullMonth.string(from: day.startDate) }

    /// `"Oct"` — chart axis.
    public static func monthAbbrev(_ day: CalendarDay) -> String { shortMonth.string(from: day.startDate) }

    /// `"14:05"` in Dubai time.
    public static func timeLabel(_ date: Date) -> String { time.string(from: date) }

    /// `"8 Oct 2026, 14:05"` in Dubai time (the transaction sheet, SMS evidence).
    public static func dateTimeLabel(_ date: Date) -> String { dayTime.string(from: date) }

    /// `"Due in 5 days"`, `"Due today"`, `"Due tomorrow"`, `"Overdue by 2 days"`.
    public static func dueLabel(_ due: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        let days = today.days(until: due)
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case let d where d > 1: return "Due in \(d) days"
        case -1: return "Overdue by 1 day"
        default: return "Overdue by \(-days) days"
        }
    }

    // MARK: - timestamptz parsing

    /// Parses Postgres/PostgREST timestamps: `2026-10-08T09:15:02.123456+00:00`,
    /// `2026-10-08 09:15:02+04`, `2026-10-08T09:15:02Z`. Fractions beyond
    /// milliseconds are truncated (ISO8601DateFormatter reads at most three).
    public static func parseTimestamp(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // Normalise a bare "+04" zone to "+04:00".
        if let range = s.range(of: #"[+-]\d{2}$"#, options: .regularExpression) {
            s.replaceSubrange(range, with: s[range] + ":00")
        }
        var hasFraction = false
        if let dot = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = s[dot].dropFirst()
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(dot, with: "." + millis)
            hasFraction = true
        }
        let input = s
        return hasFraction ? isoFractional.withLock { $0.date(from: input) } : isoWhole.withLock { $0.date(from: input) }
    }

    /// Canonical wire form for timestamps we send (`received_at`).
    public static func isoTimestamp(_ date: Date) -> String {
        isoFractional.withLock { $0.string(from: date) }
    }

    // One formatter per shape, built once: about two timestamps per decoded
    // transaction row used to allocate one each (IOS-26). ISO8601DateFormatter
    // isn't Sendable, so each sits behind a lock. (`Date.ISO8601FormatStyle`
    // is, but it truncates on output, so a saved outbox date would drift by a
    // millisecond per save.) It has no locale; its output is always ASCII.
    // Timestamps are instants: the wire form stays UTC (`…Z`) and the input
    // carries its own offset. Dubai matters only for calendar days and labels.
    private static let isoFractional = Mutex(isoFormatter([.withInternetDateTime, .withFractionalSeconds]))
    private static let isoWhole = Mutex(isoFormatter([.withInternetDateTime]))

    private static func isoFormatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        f.formatOptions = options
        return f
    }
}

/// A Postgres `date`: a calendar day with no time and no zone. Decodes from and
/// encodes to `"yyyy-MM-dd"`.
public struct CalendarDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The Dubai calendar day containing `date`.
    public init(date: Date) {
        let c = LedgerDates.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init?(iso: String) {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CalendarDay(iso: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "'\(raw)' is not a date")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    /// Midnight in Dubai.
    public var startDate: Date {
        LedgerDates.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public var startOfMonth: CalendarDay { CalendarDay(year: year, month: month, day: 1) }

    public var endOfMonth: CalendarDay {
        adding(months: 1).startOfMonth.adding(days: -1)
    }

    public func adding(days: Int) -> CalendarDay {
        CalendarDay(date: LedgerDates.calendar.date(byAdding: .day, value: days, to: startDate.addingTimeInterval(12 * 3600))!)
    }

    /// Calendar month arithmetic; the day clamps (31 Jan + 1 month = 28/29 Feb).
    public func adding(months: Int) -> CalendarDay {
        let moved = LedgerDates.calendar.date(byAdding: .month, value: months, to: startDate.addingTimeInterval(12 * 3600))!
        return CalendarDay(date: moved)
    }

    /// Whole days from `self` to `other` (negative if `other` is earlier).
    public func days(until other: CalendarDay) -> Int {
        LedgerDates.calendar.dateComponents([.day], from: startDate, to: other.startDate).day ?? 0
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
