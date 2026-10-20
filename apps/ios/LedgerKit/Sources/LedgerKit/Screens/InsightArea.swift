import Foundation

/// Which mode an insight belongs to (Wealth mode): the bank-account kinds show on Wealth's
/// Overview and nowhere in Spending; everything else (annual_fee included: it is about a card)
/// stays in Spending's Overview and feed. A kind this build doesn't know stays in Spending, where
/// the feed lists it under "Other".
public enum InsightArea: String, Sendable, Hashable {
    case spending, wealth

    public static let wealthKinds: Set<String> = ["balance_stale", "balance_drift", "salary_late"]
}

/// Where a Wealth insight leads.
public enum WealthInsightTarget: Hashable, Sendable {
    /// The bank account's ledger (balance_stale, balance_drift).
    case account(accountCode: String)
    /// The Cash flow tab (salary_late: income not in yet).
    case cashFlow

    public var label: String {
        switch self {
        case .account: "See the account"
        case .cashFlow: "See cash flow"
        }
    }
}

extension Insight {
    public var area: InsightArea { InsightArea.wealthKinds.contains(kind) ? .wealth : .spending }

    /// A Wealth insight's screen; nil for a Spending one, or one whose account code is missing.
    public var wealthTarget: WealthInsightTarget? {
        guard area == .wealth else { return nil }
        if let account = data.accountCode { return .account(accountCode: account) }
        return kind == "salary_late" ? .cashFlow : nil
    }
}

extension Array where Element == Insight {
    /// The insights one mode shows.
    public func `in`(_ area: InsightArea) -> [Insight] { filter { $0.area == area } }
}
