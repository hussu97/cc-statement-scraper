import Foundation
import Supabase

/// `termsheet-extract`'s answer (contract `docs/contracts/termsheet-v1.md`): the draft terms read
/// from a term sheet, and what to check before saving. Decoded with explicit snake_case keys and no
/// key strategy, so `extracted_terms` (the model's raw answer, kept for audit) round-trips as sent.
public struct TermSheetExtract: Decodable, Sendable, Hashable {
    public let draft: NoteDraft
    public let warnings: [String]

    public init(draft: NoteDraft, warnings: [String]) {
        self.draft = draft
        self.warnings = warnings
    }

    public static func decode(_ data: Data) throws -> TermSheetExtract {
        try JSONDecoder().decode(TermSheetExtract.self, from: data)
    }
}

/// The draft as `termsheet-extract` returns it and `create_structured_note` takes it back. Every
/// number stays the decimal string it arrived as; the review corrects the name and the symbols.
public struct NoteDraft: Codable, Sendable, Hashable {
    public var name: String
    public var terms: Terms
    public let termsheetPath: String?
    public let termsheetFilename: String?
    public let extractedTerms: AnyJSON?

    enum CodingKeys: String, CodingKey {
        case name, terms
        case termsheetPath = "termsheet_path", termsheetFilename = "termsheet_filename", extractedTerms = "extracted_terms"
    }

    public struct Terms: Codable, Sendable, Hashable {
        public var productName: String
        public var isin: String?
        public var issuer: String?
        public var guarantor: String?
        public var currency: String
        public var denomination: String
        public var issuePricePct: String
        public var strikeDate: String
        public var issueDate: String?
        public var finalValuationDate: String
        public var maturityDate: String
        public var underlyings: [Underlying]
        public var observations: [Observation]
        public var payout: [Branch]

        enum CodingKeys: String, CodingKey {
            case productName = "product_name", isin, issuer, guarantor, currency, denomination
            case issuePricePct = "issue_price_pct", strikeDate = "strike_date", issueDate = "issue_date"
            case finalValuationDate = "final_valuation_date", maturityDate = "maturity_date"
            case underlyings, observations, payout
        }
    }

    public struct Underlying: Codable, Sendable, Hashable {
        public var name: String
        public var symbol: String
        public var bloombergCode: String?
        public var isin: String?
        public var exchange: String?
        public var initialLevel: String

        enum CodingKeys: String, CodingKey {
            case name, symbol, isin, exchange
            case bloombergCode = "bloomberg_code", initialLevel = "initial_level"
        }
    }

    public struct Observation: Codable, Sendable, Hashable {
        public var obsDate: String
        public var payDate: String
        public var couponRatePct: String?
        public var couponBarrierPct: String?
        public var couponMemory: Bool
        public var autocallTriggerPct: String?
        public var autocallAmountPct: String?

        enum CodingKeys: String, CodingKey {
            case obsDate = "obs_date", payDate = "pay_date", couponRatePct = "coupon_rate_pct"
            case couponBarrierPct = "coupon_barrier_pct", couponMemory = "coupon_memory"
            case autocallTriggerPct = "autocall_trigger_pct", autocallAmountPct = "autocall_amount_pct"
        }
    }

    public struct Branch: Codable, Sendable, Hashable {
        public var minWorstPct: String
        public var interceptPct: String
        public var slope: String
        public var settlement: String
        /// For the review only; not stored.
        public var description: String?

        enum CodingKeys: String, CodingKey {
            case minWorstPct = "min_worst_pct", interceptPct = "intercept_pct", slope, settlement, description
        }
    }
}

extension NoteDraft {
    /// The schedule in one line (`NoteText.scheduleSummary`).
    public var scheduleSummary: String {
        NoteText.scheduleSummary(terms.observations.map {
            NoteText.ScheduleEntry(obsDate: CalendarDay(iso: $0.obsDate),
                                   couponRatePct: $0.couponRatePct.flatMap(LedgerDecimal.parse),
                                   couponBarrierPct: $0.couponBarrierPct.flatMap(LedgerDecimal.parse),
                                   couponMemory: $0.couponMemory,
                                   autocallTriggerPct: $0.autocallTriggerPct.flatMap(LedgerDecimal.parse))
        })
    }

    /// The terms in one line: `"USD · 1,000 denomination at 74.5% · strike 30 Apr 2026 · matures 8 Dec 2027"`.
    public var termsSummary: String {
        let t = terms
        var parts = [t.currency.uppercased()]
        if let d = NoteDraftForm.decimal(t.denomination) {
            parts.append("\(MoneyFormat.plain(d)) denomination at \(NoteText.pct(NoteDraftForm.decimal(t.issuePricePct)))")
        }
        if let strike = CalendarDay(iso: t.strikeDate) { parts.append("strike \(LedgerDates.fullDayLabel(strike))") }
        if let maturity = CalendarDay(iso: t.maturityDate) { parts.append("matures \(LedgerDates.fullDayLabel(maturity))") }
        return parts.joined(separator: " · ")
    }

    /// The payout branches as rows (`NoteText.payoutRows`); a branch that isn't numbers is left out.
    public var payoutRows: [NoteText.PayoutRow] {
        NoteText.payoutRows(terms.payout.compactMap { b in
            guard let min = NoteDraftForm.decimal(b.minWorstPct), let i = NoteDraftForm.decimal(b.interceptPct),
                  let s = NoteDraftForm.decimal(b.slope) else { return nil }
            return NotePayoutBranch(minWorstPct: min, interceptPct: i, slope: s, settlement: b.settlement)
        })
    }

    /// The trade date the form starts from: the issue date, else the strike date.
    public var defaultTradeDate: CalendarDay? {
        terms.issueDate.flatMap { CalendarDay(iso: $0) } ?? CalendarDay(iso: terms.strikeDate)
    }
}
