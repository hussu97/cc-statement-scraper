import Foundation

/// The hour × weekday grid of `hour_weekday_pattern` (web `TimeOfDayTab`, BACKLOG PAR-12).
public struct HourPattern: Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        public let dow: Int
        public let hour: Int
        public let amount: Decimal
        public let txnCount: Int
        /// Shade, 1 … `HeatScale.levels` (cells without spend are nil).
        public let level: Int
    }

    /// Seven rows, Monday first, of 24 hours each; nil where nothing timed was spent.
    public let rows: [[Cell?]]
    private let count: Int

    public init(rows: [HourWeekdaySpend]) {
        let scale = HeatScale(values: rows.map(\.amount))
        var grid: [[Cell?]] = Array(repeating: Array(repeating: nil, count: 24), count: 7)
        for r in rows where (1...7).contains(r.dow) && (0...23).contains(r.hour) {
            grid[r.dow - 1][r.hour] = Cell(dow: r.dow, hour: r.hour, amount: r.amount, txnCount: r.txnCount,
                                           level: scale.level(r.amount))
        }
        self.rows = grid
        count = rows.count
    }

    /// No timed spend at all (web: no rows).
    public var isEmpty: Bool { count == 0 }

    public func cell(dow: Int, hour: Int) -> Cell? {
        guard (1...7).contains(dow), (0...23).contains(hour) else { return nil }
        return rows[dow - 1][hour]
    }

    /// Column headings: every third hour (`"00"`, `"03"` …), blank between (web).
    public static let hourLabels: [String] = (0..<24).map { $0 % 3 == 0 ? pad($0) : "" }

    /// `"Monday, 09:00–10:00"`.
    public static func slotLabel(dow: Int, hour: Int) -> String {
        "\(AnalysisFormat.weekdaysLong[(dow - 1) % 7]), \(pad(hour)):00–\(pad((hour + 1) % 24)):00"
    }

    /// `"Monday, 09:00–10:00 · AED 120 · 2 transactions"`; nil for a cell without spend.
    public func readout(dow: Int, hour: Int) -> String? {
        guard let c = cell(dow: dow, hour: hour) else { return nil }
        return "\(Self.slotLabel(dow: dow, hour: hour)) · \(AnalysisFormat.total(c.amount)) · "
            + AnalysisFormat.count(c.txnCount, "transaction")
    }

    /// VoiceOver per cell: `"Monday 09:00: AED 120, 2 transactions"`.
    public func accessibilityLabel(dow: Int, hour: Int) -> String {
        let c = cell(dow: dow, hour: hour)
        return "\(AnalysisFormat.weekdaysLong[(dow - 1) % 7]) \(Self.pad(hour)):00: \(AnalysisFormat.total(c?.amount ?? 0)), "
            + AnalysisFormat.count(c?.txnCount ?? 0, "transaction")
    }

    public static let title = "When you spend"
    public static let hint = "Times are in Dubai. Tap a cell for details."
    public static let footnote = "Only purchases seen by a bank SMS carry an exact time, so statement-only transactions aren't counted here."
    public static let emptyTitle = "No timed transactions in this range"
    public static let emptyBody = "Only purchases seen by a bank SMS carry an exact time. Statement-only transactions have a date but no time, so they can't appear here."

    static func pad(_ h: Int) -> String { h < 10 ? "0\(h)" : "\(h)" }
}

/// `yoy_compare` for one year (web `YoyTab`): the year's months beside the year before's.
public struct YearComparison: Sendable, Hashable {
    public struct Month: Sendable, Hashable, Identifiable {
        public var id: Int { month }
        public let month: Int
        /// `"Oct"` (axis), `"October"` (readout).
        public let label: String
        public let title: String
        public let thisYear: Decimal
        public let lastYear: Decimal
    }

    public struct Readout: Sendable, Hashable {
        /// `"October"`, `"October so far"` for the current month.
        public let title: String
        /// `"2026  AED 3,200"`, `"2025  AED 2,900"`.
        public let thisYear: String
        public let lastYear: String
        /// Against the year before: `"+10%"` (more: a warning), `"−8%"`, `"±0%"`, `"New"`; nil
        /// for a month still to come or with no spend in either year.
        public let change: AnalysisChip?
    }

    public let year: Int
    public let months: [Month]

    public init(year: Int, rows: [YearOverYearMonth]) {
        self.year = year
        months = rows.sorted { $0.month < $1.month }.compactMap { r in
            guard (1...12).contains(r.month) else { return nil }
            let first = CalendarDay(year: year, month: r.month, day: 1)
            return Month(month: r.month, label: LedgerDates.monthAbbrev(first), title: LedgerDates.monthName(first),
                         thisYear: r.thisYear, lastYear: r.lastYear)
        }
    }

    public static let eyebrow = "Year over year"
    /// `"2026 against 2025"`.
    public var title: String { "\(year) against \(year - 1)" }
    public var thisYearLabel: String { String(year) }
    public var lastYearLabel: String { String(year - 1) }

    /// Nothing spent in either year (web: an all-zero series proves the empty state).
    public var isEmpty: Bool { months.allSatisfy { $0.thisYear == 0 && $0.lastYear == 0 } }
    public var emptyTitle: String { "No spending in \(year) or \(year - 1)" }
    public static let emptyBody = "Choose another year, or import older statements to compare against."

    /// The years the picker offers, newest first (web `yearOptions`).
    public static func yearOptions(currentYear: Int, count: Int = 6) -> [Int] {
        (0..<count).map { currentYear - $0 }
    }

    /// The month the readout shows: `month`, else this month in the current year, else December.
    public func readout(month: Int?, today: CalendarDay = LedgerDates.today()) -> Readout? {
        let wanted = month ?? (year == today.year ? today.month : 12)
        guard let m = months.first(where: { $0.month == wanted }) else { return nil }
        let isCurrent = year == today.year && m.month == today.month
        let isFuture = year > today.year || year == today.year && m.month > today.month
        return Readout(title: isCurrent ? "\(m.title) so far" : m.title,
                       thisYear: "\(year)  \(AnalysisFormat.total(m.thisYear))",
                       lastYear: "\(year - 1)  \(AnalysisFormat.total(m.lastYear))",
                       change: isFuture ? nil : Self.change(m.thisYear, against: m.lastYear))
    }

    /// The month's change against the year before, as `CategorySpend.changeChip` words it.
    static func change(_ now: Decimal, against before: Decimal) -> AnalysisChip? {
        guard before > 0 else { return now > 0 ? AnalysisChip("New", .neutral) : nil }
        let pct = MoneyFormat.rounded((now - before) / before * 100, scale: 0)
        if pct == 0 { return AnalysisChip("±0%", .neutral) }
        let magnitude = MoneyFormat.grouped(pct < 0 ? -pct : pct, fractionDigits: 0)
        return pct > 0 ? AnalysisChip("+\(magnitude)%", .warn) : AnalysisChip("−\(magnitude)%", .positive)
    }

    /// The chart's VoiceOver descriptor: both years, month by month.
    public var accessibility: ChartAccessibility {
        let peak = months.max { $0.thisYear < $1.thisYear }
        let summary = isEmpty ? "No spending in either year."
            : peak.map { "Highest month in \(year): \($0.title), \(AnalysisFormat.total($0.thisYear))." } ?? ""
        return ChartAccessibility(title: title, summary: summary, xTitle: "Month", categories: months.map(\.title),
                                  yTitle: "AED", series: [
                                      .init(name: thisYearLabel, values: months.map(\.thisYear.chartValue)),
                                      .init(name: lastYearLabel, values: months.map(\.lastYear.chartValue)),
                                  ])
    }
}

/// One currency of `fx_spend` in words (web `FxTab`).
public struct ForeignSpendRow: Sendable, Hashable, Identifiable {
    public var id: String { row.currency }
    public let row: FxSpend

    public init(_ row: FxSpend) { self.row = row }

    public var currency: String { row.currency }
    /// `"AED 1,240"`.
    public var amountAedLabel: String { AnalysisFormat.total(row.amountAed) }
    /// `"USD 338"`; `"—"` when the server had no original amount.
    public var originalLabel: String { row.amountOriginal.map { AnalysisFormat.total($0, currency: row.currency) } ?? "—" }
    /// `"1 USD = 3.6725 AED"`; nil without a rate.
    public var rateLabel: String? {
        row.impliedRate.map { "1 \(row.currency) = \(MoneyFormat.grouped($0, fractionDigits: 4)) AED" }
    }
    public var countLabel: String { AnalysisFormat.count(row.txnCount, "transaction") }

    /// `"Estimated"` (every one) or `"40% estimated"`; nil when none is an estimate.
    public var estimateLabel: String? {
        guard let share = row.estimatedShare, share > 0 else { return nil }
        return share >= 1 ? "Estimated" : "\(MoneyFormat.percent(share)) estimated"
    }

    /// What the estimate badge means (web tooltip).
    public var estimateNote: String? {
        guard let share = row.estimatedShare, share > 0 else { return nil }
        return "\(MoneyFormat.percent(share)) of these transactions use an estimated rate; "
            + "\(AnalysisFormat.total(row.amountAed)) may move when statements arrive."
    }

    public static func rows(_ rows: [FxSpend]) -> [ForeignSpendRow] { rows.map(ForeignSpendRow.init) }

    public static let title = "Foreign-currency spending"
    public static let footnote = "Rate paid is AED per unit of foreign currency, as charged to your card. Estimated amounts use a reference rate until the statement shows what the bank charged."
    public static let emptyTitle = "No foreign-currency spending in this range"
    public static let emptyBody = "Purchases in other currencies show up here with the rate you effectively paid."
}
