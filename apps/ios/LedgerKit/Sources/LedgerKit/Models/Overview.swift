import Foundation

/// `rpc('overview')` — one jsonb document. Money inside it is a decimal string,
/// except `top_categories[].amount`, which is a jsonb number; both decode.
public struct Overview: Decodable, Sendable, Hashable {
    public let month: CalendarDay
    public let spend: Decimal
    public let spendPrevMonth: Decimal
    public let spendPrevMonthToDate: Decimal
    public let spendAvg3m: Decimal
    public let payments: Decimal
    public let pendingCount: Int
    public let pendingAmount: Decimal
    public let uncategorizedCount: Int
    public let openReviews: Int
    public let lastSmsAt: Date?
    public let topCategories: [TopCategory]
    public let accounts: [OverviewAccount]
    public let recent: [RecentTransaction]

    // `.convertFromSnakeCase` turns `spend_avg_3m` into `spendAvg3M`.
    enum CodingKeys: String, CodingKey {
        case month, spend, spendPrevMonth, spendPrevMonthToDate, payments, pendingCount, pendingAmount
        case uncategorizedCount, openReviews, lastSmsAt, topCategories, accounts, recent
        case spendAvg3m = "spendAvg3M"
    }

    public struct TopCategory: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { categoryCode ?? "uncategorized" }
        public let categoryCode: String?
        public let name: String?
        public let colorToken: String?
        public let amount: Decimal
        public let txnCount: Int

        public var displayName: String { name ?? "Uncategorized" }
    }

    public struct OverviewAccount: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { accountCode }
        public let accountCode: String
        public let bankCode: String
        public let nickname: String?
        public let productName: String?
        public let creditLimit: Decimal?
        public let last4: String?
        public let latestStatement: LatestStatement?
        public let unbilledAed: Decimal

        public var title: String { nickname ?? productName ?? bankCode }
        /// `"•1234, •5678"`.
        public var cardsLabel: String? {
            guard let last4, !last4.isEmpty else { return nil }
            return last4.split(separator: ",").map { "•\($0)" }.joined(separator: ", ")
        }
    }

    public struct LatestStatement: Decodable, Sendable, Hashable {
        public let stmtCode: String
        public let statementDate: CalendarDay
        public let dueDate: CalendarDay?
        public let closingBalance: Decimal?
        public let minDue: Decimal?
    }

    public struct RecentTransaction: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { txnCode }
        public let txnCode: String
        public let txnDate: CalendarDay
        public let txnAt: Date?
        public let description: String?
        public let merchantName: String?
        public let amountAed: Decimal?
        public let amountOriginal: Decimal?
        public let currencyOriginal: String?
        public let direction: String
        public let status: String
        public let categoryName: String?
        public let categoryColor: String?
        public let hasSms: Bool
        public let hasStatement: Bool

        public var title: String { merchantName ?? description ?? "Unknown merchant" }
        public var isCredit: Bool { direction == "credit" }
        public var badge: EvidenceBadge { .of(status: status, hasSms: hasSms, hasStatement: hasStatement) }
        public var amountLabel: String {
            let sign = direction == "credit" ? "+ " : ""
            if let amountAed { return sign + MoneyFormat.aed(amountAed) }
            if let amountOriginal, let currencyOriginal {
                return sign + MoneyFormat.amount(amountOriginal, currency: currencyOriginal)
            }
            return "—"
        }
    }
}
