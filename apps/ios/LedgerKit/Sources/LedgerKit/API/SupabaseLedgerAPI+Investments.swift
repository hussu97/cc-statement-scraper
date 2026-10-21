import Foundation
import Supabase

/// Investments: gold and silver holdings and their prices (`20261021070429_metal_prices_and_holdings.sql`).
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

    public func closeHolding(profileCode: String, holdingCode: String) async throws {
        _ = try await read(Ignored.self) {
            try await client.rpc("close_holding", params: [
                "p_profile_code": AnyJSON.string(profileCode), "p_holding_code": .string(holdingCode),
            ]).execute()
        }
    }

    /// `save_holding`'s arguments: every one named, the optional ones null when unset.
    static func saveHoldingParams(profileCode: String, holding h: HoldingSubmission) -> [String: AnyJSON] {
        [
            "p_profile_code": .string(profileCode), "p_name": .string(h.name), "p_metal": .string(h.metal.rawValue),
            "p_grams": .string(h.grams),
            "p_karat": h.karat.map { .integer($0) } ?? .null,
            "p_fineness": h.fineness.map { .integer($0) } ?? .null,
            "p_purity": h.purity.map(AnyJSON.string) ?? .null,
            "p_form": .string(h.form.rawValue),
            "p_cost_aed": h.costAed.map(AnyJSON.string) ?? .null,
            "p_acquired_on": h.acquiredOn.map { .string($0.iso) } ?? .null,
            "p_notes": h.notes.map(AnyJSON.string) ?? .null,
            "p_holding_code": h.holdingCode.map(AnyJSON.string) ?? .null,
        ]
    }
}
