import Foundation

// Rows of the analysis RPCs (BACKLOG PAR-12), as `supabase/migrations/20261008000800_analytics.sql`
// returns them. PostgREST sends their `numeric` columns as JSON numbers; LedgerKit's `Decimal`
// overloads accept the string form too. `AnalysisContractTests` pins the column names.

/// `rpc('daily_spend')`: one row per day of the range, zero-filled by the server.
public struct DailySpend: Decodable, Sendable, Hashable, Identifiable {
    public var id: CalendarDay { day }
    public let day: CalendarDay
    public let amount: Decimal
    public let txnCount: Int

    public init(day: CalendarDay, amount: Decimal, txnCount: Int) {
        self.day = day
        self.amount = amount
        self.txnCount = txnCount
    }
}

/// `rpc('hour_weekday_pattern')`: spend per ISO weekday (`dow` 1 = Monday … 7 = Sunday) and Dubai
/// hour (0–23). Only cells with spend come back, and only transactions an SMS timed count.
public struct HourWeekdaySpend: Decodable, Sendable, Hashable {
    public let dow: Int
    public let hour: Int
    public let amount: Decimal
    public let txnCount: Int

    public init(dow: Int, hour: Int, amount: Decimal, txnCount: Int) {
        self.dow = dow
        self.hour = hour
        self.amount = amount
        self.txnCount = txnCount
    }
}

/// `rpc('yoy_compare')`: twelve rows, month 1–12, each year's spend in that month (0 when none).
public struct YearOverYearMonth: Decodable, Sendable, Hashable {
    public let month: Int
    public let thisYear: Decimal
    public let lastYear: Decimal

    public init(month: Int, thisYear: Decimal, lastYear: Decimal) {
        self.month = month
        self.thisYear = thisYear
        self.lastYear = lastYear
    }
}

/// `rpc('fx_spend')`: foreign-currency spend per original currency, largest AED amount first.
public struct FxSpend: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { currency }
    public let currency: String
    /// What was spent in `currency`; refunds count negative.
    public let amountOriginal: Decimal?
    public let amountAed: Decimal
    public let txnCount: Int
    /// AED per unit of `currency`, as charged (nil when the original amounts cancel out).
    public let impliedRate: Decimal?
    /// Share of the transactions whose AED amount is a reference-rate estimate, 0…1.
    public let estimatedShare: Decimal?

    public init(currency: String, amountOriginal: Decimal?, amountAed: Decimal, txnCount: Int,
                impliedRate: Decimal?, estimatedShare: Decimal?) {
        self.currency = currency
        self.amountOriginal = amountOriginal
        self.amountAed = amountAed
        self.txnCount = txnCount
        self.impliedRate = impliedRate
        self.estimatedShare = estimatedShare
    }
}
