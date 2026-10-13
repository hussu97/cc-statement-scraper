import Foundation

/// Insights → Trends' date range (BACKLOG PAR-10): the web's presets (`RANGE_PRESETS`) or a
/// custom from/to. Every range ends no later than today, as Insights' periods do.
public enum TrendsPreset: String, CaseIterable, Identifiable, Sendable {
    case thisMonth, lastMonth, last3Months, last6Months, yearToDate, last12Months

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last3Months: "Last 3 months"
        case .last6Months: "Last 6 months"
        case .yearToDate: "Year to date"
        case .last12Months: "Last 12 months"
        }
    }

    /// The web's `presetRange`, its end clamped to `today`.
    func bounds(today: CalendarDay) -> (from: CalendarDay, to: CalendarDay) {
        let month = today.startOfMonth
        switch self {
        case .thisMonth: return (month, today)
        case .lastMonth: return (month.adding(months: -1), month.adding(days: -1))
        case .last3Months: return (month.adding(months: -2), today)
        case .last6Months: return (month.adding(months: -5), today)
        case .yearToDate: return (CalendarDay(year: today.year, month: 1, day: 1), today)
        case .last12Months: return (month.adding(months: -11), today)
        }
    }
}

/// The range picker's choices: a preset, or custom dates.
public enum TrendsRangeChoice: Hashable, Identifiable, Sendable {
    case preset(TrendsPreset)
    case custom

    public static let all: [TrendsRangeChoice] = TrendsPreset.allCases.map(TrendsRangeChoice.preset) + [.custom]

    public var id: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
    }

    public var label: String {
        switch self {
        case .preset(let preset): preset.label
        case .custom: "Custom range"
        }
    }
}

/// A from/to of Dubai calendar days, and the bucket sizes that make a readable chart of it.
public struct TrendsRange: Hashable, Sendable {
    public let from: CalendarDay
    public let to: CalendarDay
    /// The preset these dates are, if any (a custom range that equals one counts as it).
    public let preset: TrendsPreset?

    /// More bars than this is no longer a chart on a phone: a grain that would draw more is not offered.
    public static let maxBuckets = 93

    public static func preset(_ preset: TrendsPreset, today: CalendarDay = LedgerDates.today()) -> TrendsRange {
        let (from, to) = preset.bounds(today: today)
        return TrendsRange(from: from, to: to, preset: preset)
    }

    /// Custom dates: in order, and never past today.
    public static func custom(from: CalendarDay, to: CalendarDay, today: CalendarDay = LedgerDates.today()) -> TrendsRange {
        let (a, b) = from <= to ? (from, to) : (to, from)
        let start = min(a, today)
        let end = min(b, today)
        let preset = TrendsPreset.allCases.first { p in
            let bounds = p.bounds(today: today)
            return bounds.from == start && bounds.to == end
        }
        return TrendsRange(from: start, to: end, preset: preset)
    }

    /// Days in the range, both ends included.
    public var dayCount: Int { from.days(until: to) + 1 }

    /// `"1 May – 14 Oct 2026"`, `"1 Nov 2025 – 14 Oct 2026"`, `"14 Oct 2026"`.
    public var label: String {
        if from == to { return LedgerDates.fullDayLabel(to) }
        let start = from.year == to.year ? TrendsFormat.dayMonth(from) : LedgerDates.fullDayLabel(from)
        return "\(start) – \(LedgerDates.fullDayLabel(to))"
    }

    /// The bucket starts the range touches, oldest first (the first may start before `from`).
    public func buckets(_ grain: SpendGrain) -> [CalendarDay] {
        var out: [CalendarDay] = []
        var start = grain.bucketStart(of: from)
        while start <= to {
            out.append(start)
            start = grain.nextBucket(after: start)
        }
        return out
    }

    public func bucketCount(_ grain: SpendGrain) -> Int {
        switch grain {
        case .day: return dayCount
        case .week: return grain.bucketStart(of: from).days(until: grain.bucketStart(of: to)) / 7 + 1
        case .month: return (to.year - from.year) * 12 + to.month - from.month + 1
        }
    }

    /// The bucket sizes offered, largest first. Month is always offered.
    public var grains: [SpendGrain] {
        SpendGrain.trendsOrder.filter { $0 == .month || bucketCount($0) <= Self.maxBuckets }
    }

    /// The web's `defaultGrain`: days for about a month, weeks for about a quarter, else months.
    public var defaultGrain: SpendGrain {
        if dayCount <= 45 { return .day }
        if dayCount <= 120 { return .week }
        return .month
    }

    /// The reader's choice when it suits this range, else the default.
    public func grain(choosing chosen: SpendGrain?) -> SpendGrain {
        guard let chosen, grains.contains(chosen) else { return defaultGrain }
        return chosen
    }
}

extension SpendGrain {
    /// The bucket-size picker's order.
    public static let trendsOrder: [SpendGrain] = [.month, .week, .day]

    public var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// The first day of the bucket holding `day`: the day, its Monday (Postgres
    /// `date_trunc('week')`), or the 1st.
    public func bucketStart(of day: CalendarDay) -> CalendarDay {
        switch self {
        case .day: return day
        case .week:
            let weekday = LedgerDates.calendar.component(.weekday, from: day.startDate)   // 1 = Sunday
            return day.adding(days: -((weekday + 5) % 7))
        case .month: return day.startOfMonth
        }
    }

    public func nextBucket(after start: CalendarDay) -> CalendarDay {
        switch self {
        case .day: start.adding(days: 1)
        case .week: start.adding(days: 7)
        case .month: start.startOfMonth.adding(months: 1)
        }
    }

    /// The bucket's last day.
    public func bucketEnd(startingAt start: CalendarDay) -> CalendarDay {
        nextBucket(after: start).adding(days: -1)
    }

    /// The axis label: `"Oct"` (`"Oct 25"` when `withYear`), or `"6 Oct"` for days and weeks.
    public func axisLabel(_ start: CalendarDay, withYear: Bool = false) -> String {
        switch self {
        case .month:
            let month = LedgerDates.monthAbbrev(start)
            return withYear ? "\(month) \(String(format: "%02d", start.year % 100))" : month
        case .week, .day: return TrendsFormat.dayMonth(start)
        }
    }

    /// The bucket in full: `"October 2026"`, `"Week of 6 Oct 2026"`, `"Mon 6 Oct 2026"`.
    public func title(_ start: CalendarDay) -> String {
        switch self {
        case .month: LedgerDates.monthTitle(start)
        case .week: "Week of \(LedgerDates.fullDayLabel(start))"
        case .day: TrendsFormat.weekdayDay(start)
        }
    }

    /// `"By month"`: the table's heading.
    public var tableTitle: String { "By \(label.lowercased())" }
}

/// Day formats the shared `LedgerDates` doesn't have, pinned like it (`en_US_POSIX`, Dubai).
enum TrendsFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = LedgerDates.calendar
        f.locale = LedgerDates.locale
        f.timeZone = LedgerDates.timeZone
        f.dateFormat = format
        return f
    }

    private static let dayMonthFormatter = formatter("d MMM")
    private static let weekdayDayFormatter = formatter("EEE d MMM yyyy")

    /// `"6 Oct"`, never with the year.
    static func dayMonth(_ day: CalendarDay) -> String { dayMonthFormatter.string(from: day.startDate) }
    /// `"Mon 6 Oct 2026"`.
    static func weekdayDay(_ day: CalendarDay) -> String { weekdayDayFormatter.string(from: day.startDate) }
}
