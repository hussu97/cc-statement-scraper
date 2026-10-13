import Foundation

/// Heatmap shading, as the web's `components/charts/heat.ts`: quantile cut points over the
/// positive values, so shades spread across the data instead of one big day washing the rest
/// out. Shades are display only; every figure shown is the server's.
public struct HeatScale: Sendable, Hashable {
    /// Shades above "nothing": a cell is level 0 (no spend) or 1…levels.
    public static let levels = 4
    /// Ascending cut points, `levels - 1` of them (they may repeat on a small sample).
    public let thresholds: [Decimal]

    public init(values: [Decimal], levels: Int = HeatScale.levels) {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else {
            thresholds = []
            return
        }
        thresholds = (1..<levels).map { i in
            positive[min(positive.count - 1, (i * positive.count) / levels)]
        }
    }

    /// 0 for nothing spent, then 1…`thresholds.count + 1`.
    public func level(_ value: Decimal) -> Int {
        guard value > 0 else { return 0 }
        var level = 1
        for t in thresholds where value >= t { level += 1 }
        return min(level, thresholds.count + 1)
    }

    /// A level's accent strength, 0…1 (web `heatFill`: 25 % steps mixed into surface-2).
    public static func intensity(_ level: Int) -> Double {
        guard level > 0 else { return 0 }
        return Double(min(level, levels)) / Double(levels)
    }
}

/// Words the analysis screens share with the web's `labels.ts` / `money.ts`.
public enum AnalysisFormat {
    /// ISO weekdays, Monday first (web `WEEKDAYS_ISO`).
    public static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    public static let weekdaysLong = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// Web `formatTotal`: whole dirhams, with fils only for a non-zero amount under half a dirham.
    public static func total(_ value: Decimal, currency: String = "AED") -> String {
        let magnitude = value < 0 ? -value : value
        let digits = value != 0 && magnitude < Decimal(string: "0.5")! ? MoneyFormat.fractionDigits(for: currency) : 0
        return MoneyFormat.amount(value, currency: currency, fractionDigits: digits)
    }

    /// `"1 transaction"`, `"1,204 transactions"` (web `countLabel`).
    public static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(MoneyFormat.grouped(Decimal(n), fractionDigits: 0)) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    /// ISO weekday of a Dubai date, 1 = Monday … 7 = Sunday.
    public static func isoWeekday(_ day: CalendarDay) -> Int {
        let weekday = LedgerDates.calendar.component(.weekday, from: day.startDate)   // 1 = Sunday
        return (weekday + 5) % 7 + 1
    }

    /// `"Tue 14 Oct"` (web `formatDate(d, "day")`), with the year when it isn't this year's.
    public static func dayTitle(_ day: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        "\(weekdays[isoWeekday(day) - 1]) \(LedgerDates.dayLabel(day, today: today))"
    }
}

/// The calendar heatmap of `daily_spend` (web `CalendarTab`, BACKLOG PAR-12): one block per
/// month, newest first, seven columns Monday to Sunday. Days outside the range, and days after
/// today, are blank (web WEB-15: the future is neither drawn nor counted).
public struct SpendCalendar: Sendable, Hashable {
    public struct Cell: Sendable, Hashable, Identifiable {
        public var id: CalendarDay { day }
        public let day: CalendarDay
        public let amount: Decimal
        public let txnCount: Int
        /// Shade, 0 (nothing spent) … `HeatScale.levels`.
        public let level: Int
        /// `"14"`, drawn in the cell.
        public var dayNumber: String { String(day.day) }
    }

    public struct Month: Sendable, Hashable, Identifiable {
        public var id: String { String(first.iso.prefix(7)) }
        public let first: CalendarDay
        /// `"October 2026"`.
        public var title: String { LedgerDates.monthTitle(first) }
        /// Rows of seven, Monday first; nil pads before the 1st, after the month's end and
        /// outside the range.
        public let weeks: [[Cell?]]
    }

    public let from: CalendarDay
    /// The last day drawn: the range's end, or today when the range runs on past it.
    public let to: CalendarDay
    public let months: [Month]
    /// Days in the range with spend, and days in the range.
    public let activeDays: Int
    public let dayCount: Int
    private let cells: [CalendarDay: Cell]

    /// `rows` are `daily_spend` over `from…to`; days after `today` are dropped.
    public init(rows: [DailySpend], from: CalendarDay, to: CalendarDay, today: CalendarDay = LedgerDates.today()) {
        let end = min(to, today)
        let shown = rows.filter { $0.day >= from && $0.day <= end }
        let scale = HeatScale(values: shown.map(\.amount))
        var cells: [CalendarDay: Cell] = [:]
        for row in shown {
            cells[row.day] = Cell(day: row.day, amount: row.amount, txnCount: row.txnCount, level: scale.level(row.amount))
        }
        self.from = from
        self.to = end
        self.cells = cells
        activeDays = shown.filter { $0.amount > 0 }.count
        dayCount = shown.count
        var months: [Month] = []
        if from <= end {
            var first = end.startOfMonth
            while first >= from.startOfMonth {
                months.append(Self.month(first, from: from, to: end, cells: cells))
                first = first.adding(months: -1)
            }
        }
        self.months = months
    }

    private static func month(_ first: CalendarDay, from: CalendarDay, to: CalendarDay,
                              cells: [CalendarDay: Cell]) -> Month {
        let last = first.endOfMonth
        var slots: [Cell?] = Array(repeating: nil, count: AnalysisFormat.isoWeekday(first) - 1)
        for d in 1...last.day {
            let day = CalendarDay(year: first.year, month: first.month, day: d)
            let inRange = day >= from && day <= to
            slots.append(inRange ? cells[day] ?? Cell(day: day, amount: 0, txnCount: 0, level: 0) : nil)
        }
        while slots.count % 7 != 0 { slots.append(nil) }
        let weeks = stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
        return Month(first: first, weeks: weeks)
    }

    /// Nothing spent on any day drawn (web: an all-zero series proves the empty state).
    public var isEmpty: Bool { activeDays == 0 }

    public func cell(for day: CalendarDay) -> Cell? { cells[day] }

    /// `"Spent on 12 days of 31."` (web's caption under the grid).
    public var summary: String {
        "Spent on \(AnalysisFormat.count(activeDays, "day")) of \(MoneyFormat.grouped(Decimal(dayCount), fractionDigits: 0))."
    }

    /// `"1 Sep – 14 Oct"`: the days drawn.
    public func rangeLabel(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.rangeLabel(from: from, to: to, today: today)
    }

    /// VoiceOver and the readout: `"Tue 14 Oct: AED 320, 3 transactions"`.
    public static func label(_ cell: Cell, today: CalendarDay = LedgerDates.today()) -> String {
        "\(AnalysisFormat.dayTitle(cell.day, today: today)): \(AnalysisFormat.total(cell.amount)), "
            + AnalysisFormat.count(cell.txnCount, "transaction")
    }
}

extension ActivityQuery {
    /// One day's transactions (the calendar heatmap's "Open this day in Activity",
    /// web `/activity?from=day&to=day`).
    public static func onDay(_ day: CalendarDay) -> ActivityQuery {
        var query = ActivityQuery()
        query.setRange(from: day, to: day)
        return query
    }
}
