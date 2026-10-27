import Foundation
import Supabase

/// What was bought, as typed in the review: the amount, the price paid, the trade date and the
/// paying account. With the reviewed draft it becomes `create_structured_note`'s `p_draft`
/// (the port of the web's `draftProblems` and `createNoteDraft`).
public struct NoteDraftForm: Sendable, Hashable {
    public var investedAmount = ""
    /// Empty: the issue price.
    public var purchasePricePct = ""
    public var tradeDate: CalendarDay
    /// Nil: not tracked.
    public var fundingAccountCode: String?

    public init(tradeDate: CalendarDay, fundingAccountCode: String? = nil) {
        self.tradeDate = tradeDate
        self.fundingAccountCode = fundingAccountCode
    }

    /// A typed number as a decimal string (`"1,000.50"` → `"1000.50"`, `"98%"` → `"98"`,
    /// `"−24.5"` → `"-24.5"`); nil when it isn't one.
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.replacingOccurrences(of: "−", with: "-")
            .filter { $0 != "," && $0 != "%" && !$0.isWhitespace }
        guard !s.contains("e"), !s.contains("E"), !s.hasPrefix("+"), LedgerDecimal.parse(s) != nil else { return nil }
        return s
    }

    /// The cleaned value as a `Decimal` (for comparisons and wording only).
    static func decimal(_ raw: String?) -> Decimal? { clean(raw).flatMap(LedgerDecimal.parse) }

    private static func isISODate(_ s: String?) -> Bool {
        guard let s, s.count == 10 else { return false }
        return CalendarDay(iso: s) != nil
    }

    private static func isSymbol(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9^][A-Za-z0-9.^=-]{0,19}$"#, options: .regularExpression) != nil
    }

    /// Problems with the reviewed terms and the investment, as sentences; empty when it can be saved.
    public func problems(_ d: NoteDraft) -> [String] {
        var p: [String] = []
        let t = d.terms
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Give the note a name.") }
        if t.currency.trimmingCharacters(in: .whitespaces).range(of: "^[A-Za-z]{3}$", options: .regularExpression) == nil {
            p.append("The currency is a 3-letter code, e.g. USD.")
        }
        if (Self.decimal(t.denomination) ?? 0) <= 0 { p.append("Enter the denomination.") }
        if (Self.decimal(t.issuePricePct) ?? 0) <= 0 { p.append("Enter the issue price in %.") }
        for (value, label) in [(t.strikeDate, "strike date"), (t.finalValuationDate, "final valuation date"),
                               (t.maturityDate, "maturity date")] where !Self.isISODate(value) {
            p.append("Enter the \(label) (YYYY-MM-DD).")
        }
        if Self.isISODate(t.strikeDate), Self.isISODate(t.finalValuationDate), Self.isISODate(t.maturityDate),
           !(t.strikeDate <= t.finalValuationDate && t.finalValuationDate <= t.maturityDate) {
            p.append("The strike, final valuation and maturity dates must be in that order.")
        }
        if t.underlyings.isEmpty { p.append("Add at least one underlying share.") }
        for (i, u) in t.underlyings.enumerated() {
            let who = u.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Share \(i + 1)" : u.name.trimmingCharacters(in: .whitespaces)
            if !Self.isSymbol(u.symbol.trimmingCharacters(in: .whitespaces)) { p.append("\(who): enter its price symbol (e.g. AMZN).") }
            if (Self.decimal(u.initialLevel) ?? 0) <= 0 { p.append("\(who): enter its initial level.") }
        }
        if !t.payout.contains(where: { Self.decimal($0.minWorstPct) == 0 }) {
            p.append("The payout needs a branch from 0%: what is paid however far the worst share falls.")
        }
        for (i, b) in t.payout.enumerated() where [b.minWorstPct, b.interceptPct, b.slope].contains(where: { Self.clean($0) == nil }) {
            p.append("Payout row \(i + 1) has a value that isn't a number.")
        }
        if t.observations.contains(where: { !Self.isISODate($0.obsDate) || !Self.isISODate($0.payDate) }) {
            p.append("Every observation needs an observation and a payment date.")
        }
        let invested = Self.clean(investedAmount)
        if invested.flatMap(LedgerDecimal.parse).map({ $0 <= 0 }) ?? true
            || invested?.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) == nil {
            p.append("Enter how much you invested (up to 2 decimals).")
        }
        if !purchasePricePct.trimmingCharacters(in: .whitespaces).isEmpty, Self.clean(purchasePricePct) == nil {
            p.append("The price you paid is a percent, e.g. 74.5.")
        }
        var seen = Set<String>()
        return p.filter { seen.insert($0).inserted }
    }

    /// The reviewed draft and this investment as `create_structured_note`'s `p_draft`. Call after
    /// `problems` came back empty.
    public func params(_ d: NoteDraft, institution: String? = nil) -> AnyJSON {
        func text(_ s: String?) -> AnyJSON {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return .null }
            return .string(s)
        }
        func num(_ s: String?) -> AnyJSON {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty, let v = Self.clean(s) else { return .null }
            return .string(v)
        }
        let t = d.terms
        let name = d.name.trimmingCharacters(in: .whitespaces)
        let product = t.productName.trimmingCharacters(in: .whitespaces)
        let terms: [String: AnyJSON] = [
            "product_name": .string(product.isEmpty ? name : product),
            "isin": text(t.isin), "issuer": text(t.issuer), "guarantor": text(t.guarantor),
            "currency": .string(t.currency.trimmingCharacters(in: .whitespaces).uppercased()),
            "denomination": num(t.denomination), "issue_price_pct": num(t.issuePricePct),
            "strike_date": .string(t.strikeDate), "issue_date": text(t.issueDate),
            "final_valuation_date": .string(t.finalValuationDate), "maturity_date": .string(t.maturityDate),
            "underlyings": .array(t.underlyings.map { u in
                .object([
                    "name": .string(u.name.trimmingCharacters(in: .whitespaces)),
                    "symbol": .string(u.symbol.trimmingCharacters(in: .whitespaces).uppercased()),
                    "bloomberg_code": text(u.bloombergCode), "isin": text(u.isin), "exchange": text(u.exchange),
                    "initial_level": num(u.initialLevel),
                ])
            }),
            "observations": .array(t.observations.map { o in
                .object([
                    "obs_date": .string(o.obsDate), "pay_date": .string(o.payDate),
                    "coupon_rate_pct": num(o.couponRatePct), "coupon_barrier_pct": num(o.couponBarrierPct),
                    "coupon_memory": .bool(o.couponMemory),
                    "autocall_trigger_pct": num(o.autocallTriggerPct), "autocall_amount_pct": num(o.autocallAmountPct),
                ])
            }),
            "payout": .array(t.payout.map { b in
                .object([
                    "min_worst_pct": num(b.minWorstPct), "intercept_pct": num(b.interceptPct), "slope": num(b.slope),
                    "settlement": .string(b.settlement == "physical" ? "physical" : "cash"),
                ])
            }),
        ]
        return .object([
            "name": .string(name),
            "institution": text(institution),
            "termsheet_path": text(d.termsheetPath),
            "termsheet_filename": text(d.termsheetFilename),
            "extracted_terms": d.extractedTerms ?? .null,
            "terms": .object(terms),
            "investment": .object([
                "invested_amount": num(investedAmount),
                "purchase_price_pct": num(purchasePricePct),
                "nominal": .null,
                "trade_date": .string(tradeDate.iso),
                "funding_account_code": text(fundingAccountCode),
            ]),
        ])
    }
}
