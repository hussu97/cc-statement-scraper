import Foundation

/// `rpc('account_ledger')` (Wealth mode): one bank account's rows for a period like a bank
/// statement, newest first, each with its cash-flow flow and the running balance after it, plus
/// the period's opening and closing balance and money in and out. Amounts are in the account's
/// currency, as the server's decimal strings; nothing is re-derived here.
public struct AccountLedger: Decodable, Sendable, Hashable {
    public struct Account: Decodable, Sendable, Hashable {
        public let accountCode: String
        public let bankCode: String
        public let kind: String
        public let nickname: String?
        public let accountRef: String?
        public let currency: String
        public let status: String?

        public init(accountCode: String, bankCode: String, kind: String = "current", nickname: String? = nil,
                    accountRef: String? = nil, currency: String = "AED", status: String? = "active") {
            self.accountCode = accountCode
            self.bankCode = bankCode
            self.kind = kind
            self.nickname = nickname
            self.accountRef = accountRef
            self.currency = currency
            self.status = status
        }

        public var title: String { BankAccountLabel.title(kind: kind, nickname: nickname, accountRef: accountRef) }
        /// `"ADCB · Current ··· 310001"`.
        public var detail: String { "\(bankCode) · \(BankAccountLabel.kindAndRef(kind: kind, accountRef: accountRef))" }
    }

    public let account: Account
    public let from: CalendarDay
    public let to: CalendarDay
    /// Nil before the account's first evidence or with no balance checkpoint.
    public let openingBalance: Decimal?
    public let closingBalance: Decimal?
    public let moneyIn: Decimal?
    public let moneyOut: Decimal?
    /// Rows in another currency the account's figures can't include.
    public let unpricedCount: Int
    public let rows: [AccountLedgerRow]

    public init(account: Account, from: CalendarDay, to: CalendarDay, openingBalance: Decimal?, closingBalance: Decimal?,
                moneyIn: Decimal?, moneyOut: Decimal?, unpricedCount: Int = 0, rows: [AccountLedgerRow]) {
        self.account = account
        self.from = from
        self.to = to
        self.openingBalance = openingBalance
        self.closingBalance = closingBalance
        self.moneyIn = moneyIn
        self.moneyOut = moneyOut
        self.unpricedCount = unpricedCount
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case account, from, to, openingBalance, closingBalance, moneyIn, moneyOut, unpricedCount, rows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(Account.self, forKey: .account)
        from = try c.decode(CalendarDay.self, forKey: .from)
        to = try c.decode(CalendarDay.self, forKey: .to)
        openingBalance = try c.decodeIfPresent(Decimal.self, forKey: .openingBalance)
        closingBalance = try c.decodeIfPresent(Decimal.self, forKey: .closingBalance)
        moneyIn = try c.decodeIfPresent(Decimal.self, forKey: .moneyIn)
        moneyOut = try c.decodeIfPresent(Decimal.self, forKey: .moneyOut)
        unpricedCount = try c.decodeIfPresent(Int.self, forKey: .unpricedCount) ?? 0
        rows = try c.decodeIfPresent([AccountLedgerRow].self, forKey: .rows) ?? []
    }

    private var currency: String { account.currency }

    /// The period's four figures, in the account's currency; `"—"` for one the server can't know.
    public var summaryLines: [AccountLedgerSummaryLine] {
        [
            .init(label: "Opening balance", text: balanceText(openingBalance), tone: .neutral),
            .init(label: "Money in", text: moneyIn.map { "+" + MoneyFormat.amount($0, currency: currency) } ?? "—",
                  tone: (moneyIn ?? 0) > 0 ? .positive : .neutral),
            .init(label: "Money out", text: moneyOut.map { "−" + MoneyFormat.amount($0, currency: currency) } ?? "—",
                  tone: .neutral),
            .init(label: "Closing balance", text: balanceText(closingBalance), tone: .neutral),
        ]
    }

    private func balanceText(_ value: Decimal?) -> String {
        value.map { MoneyFormat.amount($0, currency: currency) } ?? "—"
    }

    /// Under the figures when they leave something out.
    public var unpricedNote: String? {
        switch unpricedCount {
        case 0: nil
        case 1: "1 transaction isn't in \(currency), so money in and out leave it out."
        default: "\(unpricedCount) transactions aren't in \(currency), so money in and out leave them out."
        }
    }

    /// The rows in day sections, newest day first (the server's order is kept within a day).
    public func sections(today: CalendarDay = LedgerDates.today()) -> [AccountLedgerDay] {
        var out: [AccountLedgerDay] = []
        for row in rows {
            if let last = out.last, last.day == row.txnDate {
                out[out.count - 1].rows.append(row)
            } else {
                out.append(AccountLedgerDay(day: row.txnDate, title: LedgerDates.relativeDayLabel(row.txnDate, today: today),
                                            rows: [row]))
            }
        }
        return out
    }

    /// `"No transactions in October yet."` / `"No transactions in September 2026."`.
    public static func emptyMessage(_ month: CalendarDay, today: CalendarDay = LedgerDates.today()) -> String {
        month.startOfMonth == today.startOfMonth
            ? "No transactions in \(LedgerDates.monthName(month)) yet."
            : "No transactions in \(LedgerDates.monthTitle(month))."
    }

    /// The rows' footnote: an unfiled transfer is one tap from being filed.
    public static let fileHint = "Tap a transaction to see it, or to file a transfer under Support, Saving or a category."
}

public struct AccountLedgerSummaryLine: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let text: String
    public let tone: Tone
}

public struct AccountLedgerDay: Sendable, Hashable, Identifiable {
    public var id: CalendarDay { day }
    public let day: CalendarDay
    public let title: String
    public var rows: [AccountLedgerRow]
}

/// One row of `account_ledger.rows`.
public struct AccountLedgerRow: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { txnCode }
    public let txnCode: String
    public let txnDate: CalendarDay
    public let txnAt: Date?
    public let status: String
    public let kind: String
    public let direction: String
    public let description: String
    public let merchantCode: String?
    public let merchantName: String?
    /// In the account's currency, unsigned; nil when it can't be priced in it.
    public let amount: Decimal?
    public let amountOriginal: Decimal?
    public let currencyOriginal: String?
    public let categoryCode: String?
    public let categoryName: String?
    public let categoryColor: String?
    /// The cash-flow flow (`CashFlowFlow`); nil for a row the cash flow doesn't count.
    public let flow: String?
    public let balanceAfter: Decimal?
    public let notes: String?
    public let hasSms: Bool
    public let transferBankCode: String?
    public let transferCardLast4: String?

    public init(txnCode: String, txnDate: CalendarDay, txnAt: Date? = nil, status: String = "posted",
                kind: String = "transfer_out", direction: String = "debit", description: String = "",
                merchantCode: String? = nil, merchantName: String? = nil, amount: Decimal?,
                amountOriginal: Decimal? = nil, currencyOriginal: String? = nil, categoryCode: String? = nil,
                categoryName: String? = nil, categoryColor: String? = nil, flow: String?, balanceAfter: Decimal?,
                notes: String? = nil, hasSms: Bool = false, transferBankCode: String? = nil,
                transferCardLast4: String? = nil) {
        self.txnCode = txnCode
        self.txnDate = txnDate
        self.txnAt = txnAt
        self.status = status
        self.kind = kind
        self.direction = direction
        self.description = description
        self.merchantCode = merchantCode
        self.merchantName = merchantName
        self.amount = amount
        self.amountOriginal = amountOriginal
        self.currencyOriginal = currencyOriginal
        self.categoryCode = categoryCode
        self.categoryName = categoryName
        self.categoryColor = categoryColor
        self.flow = flow
        self.balanceAfter = balanceAfter
        self.notes = notes
        self.hasSms = hasSms
        self.transferBankCode = transferBankCode
        self.transferCardLast4 = transferCardLast4
    }

    enum CodingKeys: String, CodingKey {
        case txnCode, txnDate, txnAt, status, kind, direction, description, merchantCode, merchantName, amount
        case amountOriginal, currencyOriginal, categoryCode, categoryName, categoryColor, flow, balanceAfter
        case notes, hasSms, transferBankCode, transferCardLast4
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        txnCode = try c.decode(String.self, forKey: .txnCode)
        txnDate = try c.decode(CalendarDay.self, forKey: .txnDate)
        txnAt = try c.decodeIfPresent(Date.self, forKey: .txnAt)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "posted"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        direction = try c.decode(String.self, forKey: .direction)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        merchantCode = try c.decodeIfPresent(String.self, forKey: .merchantCode)
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        amountOriginal = try c.decodeIfPresent(Decimal.self, forKey: .amountOriginal)
        currencyOriginal = try c.decodeIfPresent(String.self, forKey: .currencyOriginal)
        categoryCode = try c.decodeIfPresent(String.self, forKey: .categoryCode)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
        categoryColor = try c.decodeIfPresent(String.self, forKey: .categoryColor)
        flow = try c.decodeIfPresent(String.self, forKey: .flow)
        balanceAfter = try c.decodeIfPresent(Decimal.self, forKey: .balanceAfter)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        hasSms = try c.decodeIfPresent(Bool.self, forKey: .hasSms) ?? false
        transferBankCode = try c.decodeIfPresent(String.self, forKey: .transferBankCode)
        transferCardLast4 = try c.decodeIfPresent(String.self, forKey: .transferCardLast4)
    }

    public var isCredit: Bool { direction == "credit" }

    /// The merchant, else the bank's description, else what kind of row it is.
    public var title: String {
        if let merchantName, !merchantName.isEmpty { return merchantName }
        if !description.isEmpty { return description }
        return kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// `"+AED 45,000.00"` / `"−AED 1,500.00"` in the account's currency; a row it can't price
    /// shows its own amount (`"−USD 12.00"`).
    public func amountText(currency: String) -> String {
        let sign = isCredit ? "+" : "−"
        if let amount { return sign + MoneyFormat.amount(amount, currency: currency) }
        if let amountOriginal, let currencyOriginal { return sign + MoneyFormat.amount(amountOriginal, currency: currencyOriginal) }
        return "—"
    }

    /// `"Balance AED 38,420.15"`; nil when the server can't anchor it.
    public func balanceText(currency: String) -> String? {
        balanceAfter.map { "Balance " + MoneyFormat.amount($0, currency: currency) }
    }

    /// The row's caption: its category, else nothing (the flow chip says what it is).
    public var caption: String? {
        var parts: [String] = []
        if let categoryName, !categoryName.isEmpty { parts.append(categoryName) }
        if let bank = transferBankCode {
            parts.append((isCredit ? "From " : "Paid to ") + bank + (transferCardLast4.map { " •\($0)" } ?? ""))
        }
        if status == "void" || status == "orphaned" { parts.append(status.capitalized) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The flow chip (`CashFlowFlow`); nil for a row with no flow.
    public var flowLabel: String? { flow.map(CashFlowFlow.chipLabel) }
    public var flowTone: Tone { flow.map(CashFlowFlow.tone) ?? .neutral }
}

/// `rpc('bank_balance_series')`: an end-of-day balance (Dubai days); nil before the account's
/// first evidence or with no checkpoint.
public struct BalancePoint: Decodable, Sendable, Hashable, Identifiable {
    public var id: CalendarDay { date }
    public let date: CalendarDay
    public let balance: Decimal?

    public init(date: CalendarDay, balance: Decimal?) {
        self.date = date
        self.balance = balance
    }
}

public enum BalanceSeries {
    /// How many days the account chart shows.
    public static let days = 90

    /// The days with a known balance, oldest first.
    public static func known(_ points: [BalancePoint]) -> [(date: CalendarDay, balance: Decimal)] {
        points.compactMap { p in p.balance.map { (p.date, $0) } }.sorted { $0.date < $1.date }
    }

    /// A line needs two known days.
    public static func showsChart(_ points: [BalancePoint]) -> Bool { known(points).count >= 2 }

    /// Under the chart, or instead of it.
    public static func note(_ points: [BalancePoint]) -> String {
        showsChart(points)
            ? "End-of-day balance over the last \(days) days, from the balances you entered or the bank's SMS."
            : "The balance chart starts once the account has a balance and some activity."
    }
}
