import Foundation

/// The investment RPCs: holdings of every kind, their prices, values, flows and returns, linked
/// payments and saving by holding. Part of `LedgerAPI`; implemented in
/// `SupabaseLedgerAPI+Investments.swift`. Every figure is the server's.
public protocol InvestmentsAPI: Sendable {
    /// `rpc('holdings_valuation')`: each active holding valued (metals at Dubai retail rates), gains vs
    /// what went in, the 24-hour change, the latest prices and totals (members).
    func holdingsValuation(profileCode: String) async throws -> HoldingsValuation
    /// `rpc('holdings_value_series')`: per Dubai day, the holdings held then at that day's prices and
    /// values, and their cost to date (members; at most 400 days).
    func holdingsValueSeries(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [HoldingValuePoint]
    /// `rpc('metal_price_series')`: a quote's last AED/gram price per Dubai day (signed in; at most 400 days).
    func metalPriceSeries(quote: MetalQuote, from: CalendarDay, to: CalendarDay) async throws -> [MetalPricePoint]
    /// `rpc('save_holding')`: adds (no `holdingCode`) or edits a holding; returns its code (owners;
    /// 42501 otherwise, 22023 with a readable message for bad input, P0002 for an unknown holding).
    func saveHolding(profileCode: String, holding: HoldingSubmission) async throws -> String
    /// `rpc('close_holding')`: the holding stops counting; the row is kept (owners; P0002 when unknown).
    func closeHolding(profileCode: String, holdingCode: String) async throws
    /// `rpc('holding_detail')`: a holding's active flows (with the paying transaction) and recorded values.
    func holdingDetail(profileCode: String, holdingCode: String) async throws -> HoldingDetail
    /// `rpc('holding_returns')`: per holding and in total for a period (start, added, income, growth, %, XIRR).
    func holdingReturns(profileCode: String, period: ReturnsPeriod) async throws -> HoldingReturns
    /// `rpc('record_holding_value')`: a plan's or broker account's value, or a unit price (owners).
    func recordHoldingValue(profileCode: String, value: ValueSubmission) async throws
    /// `rpc('add_holding_flow')`: money in, out or income not paid through the ledger (owners).
    func addHoldingFlow(profileCode: String, flow: FlowSubmission) async throws
    /// `rpc('remove_holding_flow')`: removes a flow (a metal's cost excepted; owners; P0002 when unknown).
    func removeHoldingFlow(profileCode: String, flowCode: String) async throws
    /// `rpc('link_transaction')`: links a payment to a holding, or unlinks it (nil) for good (owners).
    func linkTransaction(profileCode: String, txnCode: String, holdingCode: String?) async throws
    /// `rpc('cash_flow_savings')`: each month's saving by holding (holding nil: by category only),
    /// for the whole ledger or one account.
    func cashFlowSavings(profileCode: String, from: CalendarDay, to: CalendarDay,
                         accountCode: String?) async throws -> [SavingByHolding]
}
