import Foundation

/// The months a month-scoped screen can show: from the ledger's first
/// transaction (`filter_meta.date_range.min`) to the current Dubai month.
/// Never later than today's month — there is nothing to show in the future.
public struct MonthRange: Sendable, Hashable {
    /// First day of the earliest month.
    public let earliest: CalendarDay
    /// First day of the current month.
    public let latest: CalendarDay

    /// How far back the switcher goes before `filter_meta` has said where the
    /// ledger's history starts (or when it could not be loaded).
    public static let fallbackMonths = 24

    /// - Parameter firstDay: the ledger's earliest transaction date; nil when
    ///   unknown, which allows `fallbackMonths` of history.
    public init(firstDay: CalendarDay?, today: CalendarDay = LedgerDates.today()) {
        let latest = today.startOfMonth
        let earliest = firstDay?.startOfMonth ?? latest.adding(months: -Self.fallbackMonths)
        self.latest = latest
        self.earliest = min(earliest, latest)
    }

    public func contains(_ month: CalendarDay) -> Bool {
        (earliest...latest).contains(month.startOfMonth)
    }

    /// The month itself (first day) when in range, else the nearest end.
    public func clamp(_ month: CalendarDay) -> CalendarDay {
        min(max(month.startOfMonth, earliest), latest)
    }

    /// Every month, newest first (first days).
    public var months: [CalendarDay] {
        var out: [CalendarDay] = []
        var cursor = latest
        while cursor >= earliest {
            out.append(cursor)
            cursor = cursor.adding(months: -1)
        }
        return out
    }

    /// The picker's sections: newest year first, its months newest first.
    public var years: [YearGroup] {
        var groups: [YearGroup] = []
        for month in months {
            if groups.last?.year == month.year {
                groups[groups.count - 1].months.append(month)
            } else {
                groups.append(YearGroup(year: month.year, months: [month]))
            }
        }
        return groups
    }

    public struct YearGroup: Sendable, Hashable, Identifiable {
        public var id: Int { year }
        public let year: Int
        public var months: [CalendarDay]
        public var title: String { String(year) }
    }
}

extension LedgerDates {
    /// `"This month"` for the current month, else `"September 2026"` — the
    /// trailing label of a month-scoped card.
    public static func monthScopeLabel(_ month: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        month.startOfMonth == today.startOfMonth ? "This month" : monthTitle(month)
    }

    /// `"this month"` / `"in September"` / `"in September 2025"`, for sentences.
    public static func monthPhrase(_ month: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        if month.startOfMonth == today.startOfMonth { return "this month" }
        return month.year == today.year ? "in \(monthName(month))" : "in \(monthTitle(month))"
    }
}
