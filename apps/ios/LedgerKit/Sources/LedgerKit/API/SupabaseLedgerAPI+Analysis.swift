import Foundation
import Supabase

/// The analysis RPCs (BACKLOG PAR-12), called with the arguments the web sends
/// (apps/web/src/data/analytics.ts: `rangeArgs`, `p_year`).
extension SupabaseLedgerAPI {
    public func dailySpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [DailySpend] {
        try await rpc("daily_spend", [DailySpend].self, Self.rangeParams(profileCode, from, to))
    }

    public func hourWeekdayPattern(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [HourWeekdaySpend] {
        try await rpc("hour_weekday_pattern", [HourWeekdaySpend].self, Self.rangeParams(profileCode, from, to))
    }

    public func yearOverYear(profileCode: String, year: Int) async throws -> [YearOverYearMonth] {
        try await rpc("yoy_compare", [YearOverYearMonth].self,
                      ["p_profile_code": .string(profileCode), "p_year": .integer(year)])
    }

    public func fxSpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [FxSpend] {
        try await rpc("fx_spend", [FxSpend].self, Self.rangeParams(profileCode, from, to))
    }

    static func rangeParams(_ profileCode: String, _ from: CalendarDay, _ to: CalendarDay) -> [String: AnyJSON] {
        ["p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso)]
    }
}
