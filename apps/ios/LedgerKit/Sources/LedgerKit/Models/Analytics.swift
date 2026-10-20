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
    /// `(amount − prev_amount) / prev_amount` from the server, against the previous period of
    /// the same length; nil when that period had no spend (or from a server without the field).
    public let change: Decimal?

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

/// `rpc('budget_status')`: a budget and its figures for the month. With
/// `p_include_inactive` the ledger's other budgets come too, `isEffective` false.
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
    /// The card a card budget counts (nil: every card), its server-made name
    /// (nickname, else `"BANK · product"`) and bank.
    public let accountCode: String?
    public let accountName: String?
    public let bankCode: String?
    /// The budget's own range: from the first of a month through the last
    /// month it applies (nil: open-ended). Nil from a server before
    /// 20261012210407 (`effectiveFrom` too).
    public let effectiveFrom: CalendarDay?
    public let effectiveTo: CalendarDay?
    /// The server's `is_effective`; absent from an older server, whose rows all count.
    let effectiveFlag: Bool?
    /// The month's pace (migration 20261013112601), null outside the current month and absent
    /// from an older server: the share of the month gone, today included (0…1); the budget's
    /// even share by today; and spent − expected (positive is over pace).
    public let expectedShare: Decimal?
    public let expectedAed: Decimal?
    public let overPaceAed: Decimal?

    /// This budget counts for the month (the server's call, CLAUDE.md §2.2): the
    /// newest of its scope (card × category) whose range covers the month.
    public var isEffective: Bool { effectiveFlag ?? true }

    enum CodingKeys: String, CodingKey {
        case budgetCode, categoryCode, categoryName, colorToken, budgetAed, spentAed, projectedAed, shareUsed
        case accountCode, accountName, bankCode, effectiveFrom, effectiveTo
        case expectedShare, expectedAed, overPaceAed
        case effectiveFlag = "isEffective"
    }

    public init(budgetCode: String, categoryCode: String?, categoryName: String?, colorToken: String?,
                budgetAed: Decimal, spentAed: Decimal, projectedAed: Decimal, shareUsed: Decimal,
                accountCode: String? = nil, accountName: String? = nil, bankCode: String? = nil,
                isEffective: Bool = true, effectiveFrom: CalendarDay? = nil, effectiveTo: CalendarDay? = nil,
                expectedShare: Decimal? = nil, expectedAed: Decimal? = nil, overPaceAed: Decimal? = nil) {
        self.budgetCode = budgetCode
        self.categoryCode = categoryCode
        self.categoryName = categoryName
        self.colorToken = colorToken
        self.budgetAed = budgetAed
        self.spentAed = spentAed
        self.projectedAed = projectedAed
        self.shareUsed = shareUsed
        self.accountCode = accountCode
        self.accountName = accountName
        self.bankCode = bankCode
        self.effectiveFlag = isEffective
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.expectedShare = expectedShare
        self.expectedAed = expectedAed
        self.overPaceAed = overPaceAed
    }

    /// `"All spending"`, `"Dining"`, `"Daily card"` or `"Dining · Daily card"` (see `BudgetScope`).
    public var title: String {
        BudgetScope.title(categoryName: categoryCode == nil ? nil : categoryName ?? "Category",
                          accountName: accountCode == nil ? nil : accountName ?? "Card")
    }

    /// A budget for one card (its logo shows beside the title).
    public var isCardBudget: Bool { accountCode != nil }
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
    /// `paid | part_paid | unpaid | overdue`; absent from older servers.
    public let paymentStatus: String?
    /// Paid towards this statement (AED); absent from older servers.
    public let amountPaid: Decimal?
    /// Header from the bank's statement SMS, lines from the cycle's history
    /// export (`v_sms_statements`); absent from older servers.
    public let fromSms: Bool?

    /// Whether this statement was paid; nil from an older server.
    public var duePayment: DuePayment? { DuePayment(status: paymentStatus, amountPaid: amountPaid) }

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
    /// `sms` for a statement made from the bank's SMS: then `balanceEquation`
    /// compares the ledger (previous closing + the cycle's transactions) with
    /// the SMS closing balance, and `ledgerGap` = bank − ledger.
    public let source: String?
    public let ledgerGap: Decimal?
    public let historyUploaded: Bool?
    /// `statement | balance_migration | none`: what the ledger started from.
    public let openingBasis: String?
    public let unpricedTxns: Int?

    public var isFromSms: Bool { source == "sms" }
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
        /// `credit_card`, `current` or `savings` (nil from a server before Phase 2d: a card).
        public var kind: String? = nil
        /// A bank account's digits after the mask.
        public var accountRef: String? = nil

        /// A card's nickname or product; a bank account's `"ADCB Salary account"` / `"ADCB Current ··· 810001"`.
        public var title: String {
            guard let kind, kind != "credit_card" else { return nickname ?? productName ?? bankCode }
            return "\(bankCode) \(BankAccountLabel.title(kind: kind, nickname: nickname, accountRef: accountRef))"
        }

        public var isBankAccount: Bool { kind == "current" || kind == "savings" }
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
