import Foundation

// Where a bank logo replaces the bank code, the text beside it keeps only the
// card: `"•1234"` instead of `"FAB •1234"`. The logo's accessibility label
// carries the bank's name.

extension LedgerTransaction {
    /// `"•1234"`, else the account nickname, else nil (the logo says it all).
    public var cardSuffix: String? {
        if let last4 = cardLast4 { return "•\(last4)" }
        return accountNickname
    }
}

extension StatementCycle {
    /// `"•1234"`, else `"Statement"` / `"History extract"`.
    public var cardSuffix: String { cardLast4.map { "•\($0)" } ?? kindLabel }
}

extension Overview.OverviewAccount {
    /// `"•1234, •5678"`, else the account title when it isn't just the bank code.
    public var cardSuffix: String? {
        cardsLabel ?? (title == bankCode ? nil : title)
    }
}
