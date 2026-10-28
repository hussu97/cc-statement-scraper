import Foundation
import Supabase

/// Investments: holdings of every kind, their prices, values, flows and returns, and linked
/// payments (`20261021070429_metal_prices_and_holdings.sql`, `20261021093154_holdings_flows_and_returns.sql`).
/// Every figure is the server's decimal string; a holding goes up as the decimal strings typed.
extension SupabaseLedgerAPI {
    public func holdingsValuation(profileCode: String) async throws -> HoldingsValuation {
        try await rpc("holdings_valuation", HoldingsValuation.self, ["p_profile_code": .string(profileCode)])
    }

    public func holdingsValueSeries(profileCode: String, from: CalendarDay,
                                    to: CalendarDay) async throws -> [HoldingValuePoint] {
        try await rpc("holdings_value_series", [HoldingValuePoint].self, [
            "p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso),
        ])
    }

    public func metalPriceSeries(quote: MetalQuote, from: CalendarDay, to: CalendarDay) async throws -> [MetalPricePoint] {
        try await rpc("metal_price_series", [MetalPricePoint].self, [
            "p_quote": .string(quote.rawValue), "p_from": .string(from.iso), "p_to": .string(to.iso),
        ])
    }

    public func saveHolding(profileCode: String, holding: HoldingSubmission) async throws -> String {
        try await rpc("save_holding", String.self, Self.saveHoldingParams(profileCode: profileCode, holding: holding))
    }

    public func trackAccountAsInvestment(profileCode: String, accountCode: String, ratePct: String?,
                                         name: String?) async throws -> String {
        try await rpc("track_account_as_investment", String.self, [
            "p_profile_code": .string(profileCode), "p_account_code": .string(accountCode),
            "p_rate_pct": ratePct.map(AnyJSON.string) ?? .null, "p_name": name.map(AnyJSON.string) ?? .null,
        ])
    }

    public func closeHolding(profileCode: String, holdingCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("close_holding", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_holding_code": .string(holdingCode),
            ]).execute()
        }
    }

    public func holdingDetail(profileCode: String, holdingCode: String) async throws -> HoldingDetail {
        try await rpc("holding_detail", HoldingDetail.self, [
            "p_profile_code": .string(profileCode), "p_holding_code": .string(holdingCode),
        ])
    }

    public func holdingReturns(profileCode: String, period: ReturnsPeriod) async throws -> HoldingReturns {
        try await rpc("holding_returns", HoldingReturns.self, [
            "p_profile_code": .string(profileCode), "p_period": .string(period.rawValue),
        ])
    }

    public func recordHoldingValue(profileCode: String, value v: ValueSubmission) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("record_holding_value", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_holding_code": .string(v.holdingCode),
                "p_value": v.value.map(AnyJSON.string) ?? .null,
                "p_unit_price": v.unitPrice.map(AnyJSON.string) ?? .null,
                "p_as_of": .string(v.asOf.iso),
            ]).execute()
        }
    }

    public func addHoldingFlow(profileCode: String, flow f: FlowSubmission) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("add_holding_flow", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_holding_code": .string(f.holdingCode),
                "p_kind": .string(f.kind.rawValue), "p_flow_date": .string(f.flowDate.iso),
                "p_amount": .string(f.amount), "p_amount_aed": f.amountAed.map(AnyJSON.string) ?? .null,
                "p_notes": f.notes.map(AnyJSON.string) ?? .null,
            ]).execute()
        }
    }

    public func removeHoldingFlow(profileCode: String, flowCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("remove_holding_flow", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_flow_code": .string(flowCode),
            ]).execute()
        }
    }

    public func linkTransaction(profileCode: String, txnCode: String, holdingCode: String?) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("link_transaction", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_txn_code": .string(txnCode),
                "p_holding_code": holdingCode.map(AnyJSON.string) ?? .null,
            ]).execute()
        }
    }

    public func cashFlowSavings(profileCode: String, from: CalendarDay, to: CalendarDay,
                                accountCode: String?) async throws -> [SavingByHolding] {
        try await rpc("cash_flow_savings", [SavingByHolding].self, [
            "p_profile_code": .string(profileCode), "p_from": .string(from.iso), "p_to": .string(to.iso),
            "p_account_code": accountCode.map(AnyJSON.string) ?? .null,
        ])
    }

    /// `save_holding`'s arguments: every one named, the optional ones null when unset. A metal
    /// sends its weight and purity; the other kinds their currency and kind's fields.
    static func saveHoldingParams(profileCode: String, holding h: HoldingSubmission) -> [String: AnyJSON] {
        func text(_ value: String?) -> AnyJSON { value.map(AnyJSON.string) ?? .null }
        return [
            "p_profile_code": .string(profileCode), "p_name": .string(h.name), "p_kind": .string(h.kind.rawValue),
            "p_metal": text(h.metal?.rawValue), "p_grams": text(h.grams),
            "p_karat": h.karat.map { .integer($0) } ?? .null,
            "p_fineness": h.fineness.map { .integer($0) } ?? .null,
            "p_purity": text(h.purity), "p_form": text(h.form?.rawValue), "p_cost_aed": text(h.costAed),
            "p_currency": text(h.currency), "p_institution": text(h.institution), "p_units": text(h.units),
            "p_symbol": text(h.symbol), "p_principal": text(h.principal), "p_rate_pct": text(h.ratePct),
            "p_maturity_on": text(h.maturityOn?.iso), "p_link_pattern": text(h.linkPattern),
            "p_link_exact": .bool(h.linkExact),
            "p_acquired_on": text(h.acquiredOn?.iso), "p_notes": text(h.notes),
            "p_holding_code": text(h.holdingCode),
        ]
    }
}
