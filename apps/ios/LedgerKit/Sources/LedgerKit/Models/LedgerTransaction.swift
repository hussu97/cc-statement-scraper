import Foundation

// Named `LedgerTransaction`, not `Transaction`: SwiftUI exports a `Transaction`
// type and the clash produces errors that name neither.

/// One row of `public.v_transactions`.
public struct LedgerTransaction: Decodable, Identifiable, Hashable, Sendable {
    public var id: String { txnCode }

    public let txnCode: String
    public let profileCode: String
    public let accountCode: String
    public let cardCode: String?
    public let status: String          // pending | posted | void | orphaned
    public let kind: String            // purchase | refund | payment | fee | interest | cash_advance | adjustment
    public let direction: String       // debit | credit
    public let txnDate: CalendarDay
    public let txnAt: Date?
    public let postingDate: CalendarDay?
    public let stmtCode: String?
    public let merchantCode: String?
    public let description: String
    public let merchantName: String?
    public let amountOriginal: Decimal
    public let currencyOriginal: String
    public let amountAed: Decimal?
    public let amountAedIsEstimate: Bool
    public let fxRate: Decimal?
    public let authAmount: Decimal?
    public let amountSource: String
    public let relatedTxnCode: String?
    public let excludeFromSpend: Bool
    public let notes: String?
    public let categoryCode: String?
    public let categoryName: String?
    public let categoryColor: String?
    public let categoryKind: String?
    public let categorySource: String?  // manual | merchant | rule | suggested
    public let bankCode: String
    public let cardLast4: String?
    public let accountNickname: String?
    public let hasSms: Bool
    public let hasStatement: Bool

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        txnCode = try c.decode(String.self, forKey: .txnCode)
        profileCode = try c.decode(String.self, forKey: .profileCode)
        accountCode = try c.decode(String.self, forKey: .accountCode)
        cardCode = try c.decodeIfPresent(String.self, forKey: .cardCode)
        status = try c.decode(String.self, forKey: .status)
        kind = try c.decode(String.self, forKey: .kind)
        direction = try c.decode(String.self, forKey: .direction)
        txnDate = try c.decode(CalendarDay.self, forKey: .txnDate)
        txnAt = try c.decodeIfPresent(Date.self, forKey: .txnAt)
        postingDate = try c.decodeIfPresent(CalendarDay.self, forKey: .postingDate)
        stmtCode = try c.decodeIfPresent(String.self, forKey: .stmtCode)
        merchantCode = try c.decodeIfPresent(String.self, forKey: .merchantCode)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        amountOriginal = try c.decode(Decimal.self, forKey: .amountOriginal)
        currencyOriginal = try c.decode(String.self, forKey: .currencyOriginal)
        amountAed = try c.decodeIfPresent(Decimal.self, forKey: .amountAed)
        amountAedIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .amountAedIsEstimate) ?? false
        fxRate = try c.decodeIfPresent(Decimal.self, forKey: .fxRate)
        authAmount = try c.decodeIfPresent(Decimal.self, forKey: .authAmount)
        amountSource = try c.decodeIfPresent(String.self, forKey: .amountSource) ?? "sms"
        relatedTxnCode = try c.decodeIfPresent(String.self, forKey: .relatedTxnCode)
        excludeFromSpend = try c.decodeIfPresent(Bool.self, forKey: .excludeFromSpend) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        categoryCode = try c.decodeIfPresent(String.self, forKey: .categoryCode)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
        categoryColor = try c.decodeIfPresent(String.self, forKey: .categoryColor)
        categoryKind = try c.decodeIfPresent(String.self, forKey: .categoryKind)
        categorySource = try c.decodeIfPresent(String.self, forKey: .categorySource)
        bankCode = try c.decode(String.self, forKey: .bankCode)
        cardLast4 = try c.decodeIfPresent(String.self, forKey: .cardLast4)
        accountNickname = try c.decodeIfPresent(String.self, forKey: .accountNickname)
        hasSms = try c.decodeIfPresent(Bool.self, forKey: .hasSms) ?? false
        hasStatement = try c.decodeIfPresent(Bool.self, forKey: .hasStatement) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case txnCode, profileCode, accountCode, cardCode, status, kind, direction, txnDate, txnAt
        case postingDate, stmtCode, merchantCode, description, merchantName, amountOriginal
        case currencyOriginal, amountAed, amountAedIsEstimate, fxRate, authAmount, amountSource
        case relatedTxnCode, excludeFromSpend, notes, categoryCode, categoryName, categoryColor
        case categoryKind, categorySource, bankCode, cardLast4, accountNickname, hasSms, hasStatement
    }
}

/// How a transaction is evidenced — the badge on every Activity row.
public enum EvidenceBadge: String, Sendable, CaseIterable {
    case pending, sms, statement, both, orphaned, void

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .sms: "SMS"
        case .statement: "Statement"
        case .both: "SMS + Statement"
        case .orphaned: "Orphaned"
        case .void: "Void"
        }
    }

    public static func of(status: String, hasSms: Bool, hasStatement: Bool) -> EvidenceBadge {
        switch status {
        case "orphaned": return .orphaned
        case "void": return .void
        default: break
        }
        if hasSms && hasStatement { return .both }
        if hasStatement { return .statement }
        if status == "pending" { return .pending }
        return .sms
    }
}

extension LedgerTransaction {
    public var badge: EvidenceBadge { .of(status: status, hasSms: hasSms, hasStatement: hasStatement) }

    /// The name shown on the row: the merchant's display name, else the raw description.
    public var title: String { merchantName ?? (description.isEmpty ? "Unknown merchant" : description) }

    /// `"− AED 45.00"` / `"+ AED 120.00"`; a credit is money back on the card.
    public var amountLabel: String {
        let sign = direction == "credit" ? "+ " : ""
        guard let aed = amountAed else {
            return sign + MoneyFormat.amount(amountOriginal, currency: currencyOriginal)
        }
        return sign + (amountAedIsEstimate ? "≈ " : "") + MoneyFormat.aed(aed)
    }

    /// `"USD 12.00"` when the card was charged in another currency, else nil.
    public var originalAmountLabel: String? {
        currencyOriginal == "AED" ? nil : MoneyFormat.amount(amountOriginal, currency: currencyOriginal)
    }

    public var isCredit: Bool { direction == "credit" }

    /// `"FAB •1234"`.
    public var cardLabel: String {
        if let last4 = cardLast4 { return "\(bankCode) •\(last4)" }
        return accountNickname ?? bankCode
    }
}
