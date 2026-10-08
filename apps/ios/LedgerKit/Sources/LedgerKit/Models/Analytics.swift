import Foundation

/// `rpc('category_breakdown')`.
public struct CategorySpend: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { categoryCode ?? "uncategorized" }
    public let categoryCode: String?
    public let name: String
    public let colorToken: String?
    public let amount: Decimal
    public let txnCount: Int
    public let share: Decimal?
    public let prevAmount: Decimal

    /// The server's share, clamped to 0…1 for drawing a bar.
    public var shareFraction: Double { min(max((share ?? 0).chartValue, 0), 1) }
    /// `"9 transactions · 42% of spend"`.
    public var detailLabel: String { "\(txnCount) transactions · \(MoneyFormat.percent(share ?? 0)) of spend" }
}

/// `rpc('spend_series')`.
public struct SpendPoint: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { bucket.iso + "|" + (groupKey ?? "-") }
    public let bucket: CalendarDay
    public let groupKey: String?
    public let groupLabel: String
    public let colorToken: String?
    public let amount: Decimal
    public let txnCount: Int

    /// Categorical axis label (`"Oct"`). Charts are given labels, not dates: a
    /// `Date` bucket is Dubai midnight, which a chart binning by the device's
    /// calendar would drop into the previous month.
    public var monthLabel: String { LedgerDates.monthAbbrev(bucket) }
}

/// `rpc('merchant_leaderboard')`.
public struct MerchantSpend: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { merchantCode ?? merchantName }
    public let merchantCode: String?
    public let merchantName: String
    public let categoryCode: String?
    public let categoryName: String?
    public let amount: Decimal
    public let txnCount: Int
    public let avgAmount: Decimal
    public let lastDate: CalendarDay
}

/// `rpc('budget_status')`.
public struct BudgetStatus: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { budgetCode }
    public let budgetCode: String
    public let categoryCode: String?
    public let categoryName: String?
    public let colorToken: String?
    public let budgetAed: Decimal
    public let spentAed: Decimal
    public let projectedAed: Decimal
    public let shareUsed: Decimal

    public var title: String { categoryName ?? "All spending" }
    /// The server's `share_used`; 1 = budget fully used.
    public var isOver: Bool { shareUsed > 1 }
    public var isProjectedOver: Bool { projectedAed > budgetAed }
}

/// `rpc('recurring_list')`.
public struct RecurringCharge: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { recurringCode }
    public let recurringCode: String
    public let merchantCode: String
    public let merchantName: String
    public let categoryName: String?
    public let cadence: String          // weekly | monthly | yearly …
    public let expectedAmount: Decimal
    public let lastAmount: Decimal
    public let priceChange: Decimal?
    public let occurrences: Int
    public let lastDate: CalendarDay
    public let nextExpected: CalendarDay?
    public let status: String
    public let annualCost: Decimal

    /// `"+12% since last charge"` when the server reports a price change.
    public var priceChangeLabel: String? {
        guard let priceChange, priceChange != 0 else { return nil }
        let sign = priceChange > 0 ? "+" : "−"
        let magnitude = priceChange < 0 ? -priceChange : priceChange
        return "\(sign)\(MoneyFormat.percent(magnitude)) vs usual"
    }
}

/// `rpc('statement_cycles')`.
public struct StatementCycle: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { stmtCode }
    public let stmtCode: String
    public let accountCode: String
    public let bankCode: String
    public let cardLast4: String?
    public let kind: String               // statement | history_extract
    public let statementDate: CalendarDay
    public let periodStart: CalendarDay?
    public let periodEnd: CalendarDay?
    public let dueDate: CalendarDay?
    public let closingBalance: Decimal?
    public let minDue: Decimal?
    public let creditLimit: Decimal?
    public let utilisation: Decimal?
    public let lineCount: Int
    public let debits: Decimal
    public let credits: Decimal
    public let reconStatus: String?       // ok | warn | fail
    public let reconChecks: ReconChecks?
    public let docCode: String?

    public var title: String {
        cardLast4.map { "\(bankCode) •\($0)" } ?? bankCode
    }
}

/// `statement_recon.checks` — every key is optional because which checks run
/// depends on what the parser could extract.
public struct ReconChecks: Decodable, Sendable, Hashable {
    public let lineCount: Int?
    public let sumDebits: Decimal?
    public let sumCredits: Decimal?
    public let heldLines: Int?
    public let smsCoverage: Decimal?
    public let debitsMatch: Bool?
    public let creditsMatch: Bool?
    public let balanceEquation: Bool?
    public let expectedClosing: Decimal?
    public let totals: String?
    public let unmatchedSms: Int?
    /// Lines without an AED amount yet: the sums are approximate, not wrong.
    public let unpricedLines: Int?
    /// No lines although the header shows activity, or all were superseded.
    public let noLines: Bool?
}

/// `rpc('filter_meta')`.
public struct FilterMeta: Decodable, Sendable, Hashable {
    public let accounts: [AccountOption]
    public let cards: [CardOption]
    public let categories: [CategoryOption]
    public let banks: [BankOption]
    public let dateRange: DateRange?

    public struct AccountOption: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { accountCode }
        public let accountCode: String
        public let bankCode: String
        public let nickname: String?
        public let productName: String?
        public var title: String { nickname ?? productName ?? bankCode }
    }

    public struct CardOption: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { cardCode }
        public let cardCode: String
        public let accountCode: String
        public let bankCode: String
        public let last4: String
        public let isSupplementary: Bool
    }

    public struct CategoryOption: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { categoryCode }
        public let categoryCode: String
        public let name: String
        public let kind: String
        public let colorToken: String?
        public let parentCode: String?
        public let archived: Bool
    }

    public struct BankOption: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { bankCode }
        public let bankCode: String
        public let name: String
    }

    public struct DateRange: Decodable, Sendable, Hashable {
        public let min: CalendarDay?
        public let max: CalendarDay?
    }

    /// Categories a transaction can be moved to: not archived, parents first.
    public var assignableCategories: [CategoryOption] { categories.filter { !$0.archived } }
}
