import Foundation

/// India mode's read (`india_overview`). Part of `LedgerAPI`; implemented in
/// `SupabaseLedgerAPI+India.swift`. Kite and Coin's own screens read `broker_portfolio` (`BrokerAPI`).
public protocol IndiaAPI: Sendable {
    /// `rpc('india_overview')`: every Zerodha Kite and Coin account in rupees, each account, and for
    /// `period` (30d, 90d, ytd, 12m) the value against invested and the period's growth (members;
    /// 22023 for another period). `available` is false for a ledger with no India account.
    func indiaOverview(profileCode: String, period: ReturnsPeriod) async throws -> IndiaOverview
}
