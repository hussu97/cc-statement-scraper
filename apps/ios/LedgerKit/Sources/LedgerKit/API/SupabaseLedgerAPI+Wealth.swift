import Foundation
import Supabase

/// Wealth mode's reads (`20261020162834_wealth_mode.sql`): an account's ledger and balance series,
/// net worth now and over time. Every figure is the server's decimal string.
extension SupabaseLedgerAPI {
    public func accountLedger(profileCode: String, accountCode: String, from: CalendarDay,
                              to: CalendarDay) async throws -> AccountLedger {
        try await rpc("account_ledger", AccountLedger.self, [
            "p_profile_code": .string(profileCode), "p_account_code": .string(accountCode),
            "p_from": .string(from.iso), "p_to": .string(to.iso),
        ])
    }

    public func bankBalanceSeries(profileCode: String, accountCode: String, from: CalendarDay,
                                  to: CalendarDay) async throws -> [BalancePoint] {
        try await rpc("bank_balance_series", [BalancePoint].self, [
            "p_profile_code": .string(profileCode), "p_account_code": .string(accountCode),
            "p_from": .string(from.iso), "p_to": .string(to.iso),
        ])
    }

    public func netWorth(profileCode: String) async throws -> NetWorth {
        try await rpc("net_worth", NetWorth.self, ["p_profile_code": .string(profileCode)])
    }

    public func netWorthSeries(profileCode: String, months: Int) async throws -> [NetWorthPoint] {
        try await rpc("net_worth_series", [NetWorthPoint].self,
                      ["p_profile_code": .string(profileCode), "p_months": .integer(months)])
    }
}
