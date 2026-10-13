import Foundation

/// One row of `rpc('anomalies')` (20261012234036_anomalies_plain_and_dismissals): a charge far
/// above what the ledger usually spends at its merchant or in its category, or a large first
/// purchase at a merchant. Every figure is the server's: `baselineMean` is the usual purchase in
/// `baselineScope` ('merchant' | 'category' | nil) and `timesUsual` is amount / usual, already
/// rounded for display (whole numbers from 3×, one decimal below). Charges an owner marked
/// "This is fine" (`dismiss_anomaly`) are left out by the server.
public struct Anomaly: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { txnCode }
    public let txnCode: String
    public let txnDate: CalendarDay
    public let description: String
    public let amount: Decimal
    /// merchant_outlier | category_outlier | new_merchant_large
    public let reason: String?
    public let baselineMean: Decimal?
    public let baselineSd: Decimal?
    public let merchantCode: String?
    public let merchantName: String?
    public let categoryCode: String?
    public let categoryName: String?
    public let baselineScope: String?
    public let timesUsual: Decimal?

    public init(txnCode: String, txnDate: CalendarDay, description: String, amount: Decimal, reason: String?,
                baselineMean: Decimal? = nil, baselineSd: Decimal? = nil, merchantCode: String? = nil,
                merchantName: String? = nil, categoryCode: String? = nil, categoryName: String? = nil,
                baselineScope: String? = nil, timesUsual: Decimal? = nil) {
        self.txnCode = txnCode
        self.txnDate = txnDate
        self.description = description
        self.amount = amount
        self.reason = reason
        self.baselineMean = baselineMean
        self.baselineSd = baselineSd
        self.merchantCode = merchantCode
        self.merchantName = merchantName
        self.categoryCode = categoryCode
        self.categoryName = categoryName
        self.baselineScope = baselineScope
        self.timesUsual = timesUsual
    }

    /// The merchant the way Activity names it, else the statement description.
    public var name: String {
        if let merchantName, !merchantName.trimmingCharacters(in: .whitespaces).isEmpty { return merchantName }
        return description
    }

    /// The reason chip (web `anomalyReasonLabel`).
    public var reasonLabel: String {
        switch reason {
        case "merchant_outlier", "category_outlier": "Higher than usual"
        case "new_merchant_large": "New merchant"
        default: "Unusual"
        }
    }

    /// `"5×"`, `"2.3×"`: the server's rounded `times_usual`, printed as is.
    public var timesLabel: String? {
        guard let timesUsual else { return nil }
        var text = MoneyFormat.grouped(timesUsual, fractionDigits: 1)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + "×"
    }

    /// One plain sentence from the server's figures only (web `anomalyExplanation`, WEB-16):
    /// "About 5× what you usually spend here (AED 100.00)",
    /// "About 10× your usual Shopping purchase (AED 300.00)",
    /// "First purchase here, about 2.3× your usual Travel purchase (AED 3,000.00)",
    /// "First purchase here".
    public var explanation: String {
        let usual = baselineMean.map { " (\(MoneyFormat.aed($0)))" } ?? ""
        var compared: String?
        if let times = timesLabel {
            switch baselineScope {
            case "merchant": compared = "\(times) what you usually spend here"
            case "category":
                compared = "\(times) " + (categoryName.map { "your usual \($0) purchase" }
                                          ?? "your usual purchase in this category")
            default: break
            }
        }
        if reason == "new_merchant_large" {
            return compared.map { "First purchase here, about \($0)\(usual)" } ?? "First purchase here"
        }
        if let compared { return "About \(compared)\(usual)" }
        return baselineMean.map { "Usually \(MoneyFormat.aed($0))" } ?? "Higher than usual"
    }
}
