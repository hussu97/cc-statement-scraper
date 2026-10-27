import Foundation
import Supabase

/// The broker sync's read (`20261027165732_swissquote_sync.sql`). The RPC answers `null` for an
/// account with no sync, which `BrokerPortfolio.decode` reads as nil.
extension SupabaseLedgerAPI {
    public func brokerPortfolio(profileCode: String, accountCode: String) async throws -> BrokerPortfolio? {
        let data: Data
        do {
            data = try await client.rpc("broker_portfolio", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_account_code": .string(accountCode),
            ]).execute().data
        } catch {
            throw Self.map(error)
        }
        return try BrokerPortfolio.decode(data)
    }

    public func brokerAccounts(profileCode: String) async throws -> [BrokerAccountSummary] {
        try await rpc("broker_accounts_summary", [BrokerAccountSummary].self, ["p_profile_code": .string(profileCode)])
    }
}
