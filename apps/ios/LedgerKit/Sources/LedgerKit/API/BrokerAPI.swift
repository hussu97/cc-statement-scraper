import Foundation

/// The broker sync's read (`20261027165732_swissquote_sync.sql`). Part of `LedgerAPI`; implemented
/// in `SupabaseLedgerAPI+Broker.swift`. Every figure is the server's.
public protocol BrokerAPI: Sendable {
    /// `rpc('broker_portfolio')`: a synced broker account's cash, positions, ended positions, daily
    /// value and last sync (members). Nil when the account has no sync.
    func brokerPortfolio(profileCode: String, accountCode: String) async throws -> BrokerPortfolio?
    /// `rpc('broker_accounts_summary')`: every synced broker account with its value, profit, live
    /// notes and the holdings it shows (members; 20261027200000).
    func brokerAccounts(profileCode: String) async throws -> [BrokerAccountSummary]
    /// `rpc('broker_position_detail')`: one position on a broker account by ISIN, its marks over
    /// time and its SIPs (members; 20261028062806). Nil when the account never marked it.
    func brokerPosition(profileCode: String, accountCode: String, isin: String) async throws -> BrokerPositionDetail?
}
