import Foundation

/// The analysis RPCs behind Insights' "More analysis" screens (BACKLOG PAR-12): the calendar
/// heatmap, time of day, year over year and foreign-currency spend. Part of `LedgerAPI`;
/// implemented in `SupabaseLedgerAPI+Analysis.swift`. Every figure is the server's.
public protocol AnalysisAPI: Sendable {
    /// `rpc('daily_spend')`: each day of `from…to`, zero-filled.
    func dailySpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [DailySpend]
    /// `rpc('hour_weekday_pattern')`: SMS-timed spend by weekday and Dubai hour.
    func hourWeekdayPattern(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [HourWeekdaySpend]
    /// `rpc('yoy_compare')`: `year` against the year before, month by month.
    func yearOverYear(profileCode: String, year: Int) async throws -> [YearOverYearMonth]
    /// `rpc('fx_spend')`: foreign-currency spend per currency in `from…to`.
    func fxSpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [FxSpend]
}
