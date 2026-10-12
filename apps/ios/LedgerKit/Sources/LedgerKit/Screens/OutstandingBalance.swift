import Foundation

/// What a card owes now, as the server computed it (`v_account_balances` via
/// `overview`). Wording only: the figures are never re-derived on the phone
/// (root CLAUDE.md §2.2). Mirrors the web's `lib/balances.ts`.
public enum OutstandingBalance {
    /// `"AED 515.26"`; a credit balance `"AED 0.84 in credit"`; `"≈ "` when an
    /// amount is estimated; `"—"` when the server has no balance.
    public static func text(_ value: Decimal?, hasEstimate: Bool = false) -> String {
        guard let value else { return "—" }
        let approx = hasEstimate ? "≈ " : ""
        if value < 0 { return "\(approx)\(MoneyFormat.aed(-value)) in credit" }
        return approx + MoneyFormat.aed(value)
    }

    /// Where the balance comes from, in one short line under it:
    /// `"Statement of 1 Oct + activity since"`, `"Card replaced 15 Sep + activity since"`.
    public static func anchorNote(_ anchor: String?, date: CalendarDay?,
                                  today: CalendarDay = LedgerDates.today()) -> String {
        let day = date.map { LedgerDates.dayLabel($0, today: today) } ?? "—"
        switch anchor {
        case "statement": return "Statement of \(day) + activity since"
        case "balance_migration": return "Card replaced \(day) + activity since"
        default: return "No balance from the bank yet"
        }
    }

    /// Why a total may not be the whole story, or nil when it is.
    public static func caveat(complete: Bool, unpricedCount: Int) -> String? {
        if complete { return nil }
        if unpricedCount > 0 {
            return "Excludes \(unpricedCount) \(unpricedCount == 1 ? "charge" : "charges") without an AED amount"
        }
        return "Some cards have no balance from the bank yet"
    }
}

extension AccountSummary {
    /// `"AED 515.26"` / `"AED 0.84 in credit"`; nil from a server without balances.
    public var owedNowText: String? {
        guard account.balanceAnchor != nil else { return nil }
        return OutstandingBalance.text(account.outstandingAed, hasEstimate: account.balanceHasEstimate ?? false)
    }

    public func owedNowNote(today: CalendarDay = LedgerDates.today()) -> String? {
        guard account.balanceAnchor != nil else { return nil }
        return OutstandingBalance.anchorNote(account.balanceAnchor, date: account.balanceAnchorDate, today: today)
    }
}

extension Overview {
    /// The total over active cards; nil from a server without it.
    public var owedNowText: String? {
        guard let outstanding else { return nil }
        return OutstandingBalance.text(outstanding, hasEstimate: outstandingHasEstimate ?? false)
    }

    public var owedNowCaveat: String? {
        guard outstanding != nil else { return nil }
        return OutstandingBalance.caveat(complete: outstandingComplete ?? true,
                                         unpricedCount: accounts.reduce(0) { $0 + ($1.balanceUnpricedCount ?? 0) })
    }
}
