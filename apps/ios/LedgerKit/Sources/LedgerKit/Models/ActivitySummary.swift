import Foundation
import Supabase

/// `rpc('activity_summary')`: the Activity header for the current search and
/// filters. Every figure is the server's (CLAUDE.md §2.2); the phone only
/// formats it.
public struct ActivitySummary: Decodable, Sendable, Hashable {
    /// Every matching row, void included (like the list).
    public let txnCount: Int
    /// Debits minus credits in AED, void and unpriced rows left out.
    public let netAed: Decimal
    /// Non-void rows without an AED amount, so not in `netAed`.
    public let unpricedCount: Int
    /// Some AED amount in the sum is an FX estimate.
    public let hasEstimate: Bool
    public let earliestDate: CalendarDay?
    public let latestDate: CalendarDay?

    public init(txnCount: Int, netAed: Decimal, unpricedCount: Int = 0, hasEstimate: Bool = false,
                earliestDate: CalendarDay? = nil, latestDate: CalendarDay? = nil) {
        self.txnCount = txnCount
        self.netAed = netAed
        self.unpricedCount = unpricedCount
        self.hasEstimate = hasEstimate
        self.earliestDate = earliestDate
        self.latestDate = latestDate
    }
}

extension ActivityQuery {
    /// The `activity_summary` arguments for these filters. The search goes raw:
    /// the server cleans it exactly as `sanitizedSearch` does. Unset filters are null.
    public func summaryParams(profileCode: String) -> [String: AnyJSON] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "p_profile_code": .string(profileCode),
            "p_from": from.map { .string($0.iso) } ?? .null,
            "p_to": to.map { .string($0.iso) } ?? .null,
            "p_account_code": accountCode.map { .string($0) } ?? .null,
            "p_card_code": cardCode.map { .string($0) } ?? .null,
            "p_category_code": uncategorizedOnly ? .null : categoryCode.map { .string($0) } ?? .null,
            "p_uncategorized": .bool(uncategorizedOnly),
            "p_status": status == .all ? .null : .string(status.rawValue),
            "p_source": source == .all ? .null : .string(source.rawValue),
            "p_q": search.isEmpty ? .null : .string(search),
            // The list's rows and these totals agree (Wealth mode's spending scope).
            "p_scope": spendingOnly ? .string("spending") : .null,
        ]
    }
}

/// What the Activity header says, formatted.
public struct ActivitySummaryHeader: Sendable, Hashable {
    /// `"1 transaction"`, `"1,234 transactions"`.
    public let countText: String
    /// `"AED 1,234.50"`; a net credit reads `"+ AED 105.50"`, like a refund row;
    /// `"≈ "` when an FX estimate is in the sum.
    public let netText: String
    public let isNetCredit: Bool
    /// `"1 Jun 2026 – 8 Oct 2026"`, one date when equal, nil with no rows.
    public let dateRangeText: String?
    /// `"excl. 3 without AED amount"`, nil when every row is priced.
    public let unpricedNote: String?

    public init(_ s: ActivitySummary) {
        countText = MoneyFormat.grouped(Decimal(s.txnCount), fractionDigits: 0)
            + (s.txnCount == 1 ? " transaction" : " transactions")
        isNetCredit = s.netAed < 0
        netText = (isNetCredit ? "+ " : "") + (s.hasEstimate ? "≈ " : "")
            + MoneyFormat.aed(isNetCredit ? -s.netAed : s.netAed)
        dateRangeText = Self.dateRange(s.earliestDate, s.latestDate)
        unpricedNote = s.unpricedCount > 0
            ? "excl. \(MoneyFormat.grouped(Decimal(s.unpricedCount), fractionDigits: 0)) without AED amount"
            : nil
    }

    static func dateRange(_ earliest: CalendarDay?, _ latest: CalendarDay?) -> String? {
        switch (earliest, latest) {
        case let (a?, b?) where a == b: LedgerDates.fullDayLabel(a)
        case let (a?, b?): "\(LedgerDates.fullDayLabel(a)) – \(LedgerDates.fullDayLabel(b))"
        case let (a?, nil), let (nil, a?): LedgerDates.fullDayLabel(a)
        case (nil, nil): nil
        }
    }
}

/// The header's three states: a placeholder while the first answer for these
/// filters loads, the figures, or nothing (a failed summary never blocks the list).
public enum ActivitySummaryDisplay: Sendable, Hashable {
    case hidden
    case placeholder
    case shown(ActivitySummaryHeader)

    public static func of(_ state: LoadState<ActivitySummary>) -> ActivitySummaryDisplay {
        switch state {
        case .idle, .failed: .hidden
        case .loading(let previous): previous.map { .shown(ActivitySummaryHeader($0)) } ?? .placeholder
        case .loaded(let s): .shown(ActivitySummaryHeader(s))
        }
    }
}
