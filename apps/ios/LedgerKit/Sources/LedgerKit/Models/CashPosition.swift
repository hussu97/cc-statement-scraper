import Foundation

/// A current or savings account (`accounts.kind`). Cards are `credit_card` and never appear here.
public enum BankAccountKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case current, savings

    public var id: String { rawValue }
    /// `"Current"` / `"Savings"`.
    public var label: String { self == .current ? "Current" : "Savings" }
}

/// `rpc('cash_position')` (Phase 2d): every active bank account's balance and the AED total, as
/// the server computes them. Money arrives as decimal strings; nothing here is re-derived.
public struct CashPosition: Decodable, Sendable, Hashable {
    /// The sum of the AED balances the server could price (`complete` says whether that is all of them).
    public let totalAed: Decimal
    public let complete: Bool
    /// Balances older than a week (`v_bank_balances.is_stale`).
    public let staleCount: Int
    /// Accounts with no balance recorded yet.
    public let missingCount: Int
    /// The oldest balance's time; nil when no account has one.
    public let asOf: Date?
    public let accounts: [BankAccountBalance]

    public init(totalAed: Decimal, complete: Bool, staleCount: Int, missingCount: Int, asOf: Date?,
                accounts: [BankAccountBalance]) {
        self.totalAed = totalAed
        self.complete = complete
        self.staleCount = staleCount
        self.missingCount = missingCount
        self.asOf = asOf
        self.accounts = accounts
    }

    /// Overview shows the cash tile only for a ledger with a bank account.
    public var hasAccounts: Bool { !accounts.isEmpty }

    /// `"AED 108,385.90"`.
    public var totalText: String { MoneyFormat.aed(totalAed) }

    /// `"As of 6 Oct"`: the oldest balance the total includes. Nil before the first balance.
    public func asOfText(now: Date = .now) -> String? {
        asOf.map { CashText.asOf($0, now: now) }
    }

    /// What the total can't vouch for, in plain words; empty when it is whole and fresh.
    public var caveats: [String] {
        var out: [String] = []
        if missingCount > 0 {
            out.append(missingCount == 1
                ? "1 account has no balance yet, so the total leaves it out."
                : "\(missingCount) accounts have no balance yet, so the total leaves them out.")
        }
        if accounts.contains(where: {
            !$0.isShownAsInvestment && $0.balance != nil && ($0.balanceAed == nil || $0.unpricedCount > 0)
        }) {
            out.append("Some amounts aren't converted to AED yet, so the total may be off.")
        }
        if staleCount > 0 {
            out.append(staleCount == 1 ? "1 balance is over a week old." : "\(staleCount) balances are over a week old.")
        }
        return out
    }

    /// The accounts card with none: owners are told how to add one.
    public static func noAccountsMessage(canEdit: Bool) -> String {
        canEdit
            ? "No bank accounts yet. Add your current or savings account with + to see its balance here."
            : "No bank accounts yet. An owner of this ledger can add them."
    }

    /// Under the total when an account is shown under Investments: it is listed, not added.
    public var investedNote: String? {
        let n = accounts.filter(\.isShownAsInvestment).count
        guard n > 0 else { return nil }
        return n == 1
            ? "The total leaves out 1 account shown under Investments, where net worth counts it."
            : "The total leaves out \(n) accounts shown under Investments, where net worth counts them."
    }

    /// The caveat tone: a total missing something warns; a stale one is information.
    public var caveatTone: Tone { complete ? .info : .warn }
}

/// One bank account in `cash_position.accounts`.
public struct BankAccountBalance: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String
    /// `current` / `savings` (kept raw: a kind this build doesn't know still lists).
    public let kind: String
    public let nickname: String?
    /// The digits after the bank's mask (`310001`).
    public let accountRef: String?
    public let currency: String
    public let balance: Decimal?
    public let balanceAed: Decimal?
    public let asOf: Date?
    /// `manual`, `sms` or `statement`: where the latest checkpoint came from.
    public let anchorSource: String?
    public let isStale: Bool
    public let unpricedCount: Int
    /// The `savings_account` holding this account is shown under Investments as; nil when it
    /// counts as cash (and before the server sent it). Such an account is out of the total.
    public let investmentHoldingCode: String?

    public init(accountCode: String, bankCode: String, kind: String, nickname: String?, accountRef: String?,
                currency: String = "AED", balance: Decimal?, balanceAed: Decimal?, asOf: Date?,
                anchorSource: String? = nil, isStale: Bool = false, unpricedCount: Int = 0,
                investmentHoldingCode: String? = nil) {
        self.accountCode = accountCode
        self.bankCode = bankCode
        self.kind = kind
        self.nickname = nickname
        self.accountRef = accountRef
        self.currency = currency
        self.balance = balance
        self.balanceAed = balanceAed
        self.asOf = asOf
        self.anchorSource = anchorSource
        self.isStale = isStale
        self.unpricedCount = unpricedCount
        self.investmentHoldingCode = investmentHoldingCode
    }

    /// `"Current ··· 310001"`, `"Savings account"` without a ref.
    public var kindAndRef: String { BankAccountLabel.kindAndRef(kind: kind, accountRef: accountRef) }

    /// The nickname, else `kindAndRef`.
    public var title: String { BankAccountLabel.title(kind: kind, nickname: nickname, accountRef: accountRef) }

    /// Under a nickname: the kind and ref, so two accounts at one bank stay apart. Nil without one.
    public var subtitle: String? { nickname.flatMap { $0.isEmpty ? nil : kindAndRef } }

    /// The line under the title: `"ADCB · Current ··· 310001"` under a nickname, else `"ADCB"`.
    public var detail: String { subtitle.map { "\(bankCode) · \($0)" } ?? bankCode }

    /// `"AED 28,650.40"`, `"USD 1,200.00"`, or `"No balance yet"`.
    public var balanceText: String {
        balance.map { MoneyFormat.amount($0, currency: currency) } ?? "No balance yet"
    }

    public var hasBalance: Bool { balance != nil }

    /// `"As of yesterday, 09:10 · from SMS"`; nil before the first balance.
    public func asOfText(now: Date = .now) -> String? {
        guard let asOf else { return nil }
        let when = CashText.asOf(asOf, now: now)
        switch anchorSource {
        case "sms": return "\(when) · from SMS"
        case "statement": return "\(when) · from statement"
        case "manual": return "\(when) · entered"
        case "broker": return "\(when) · from the broker"
        default: return when
        }
    }

    /// The row's chip: `"Over a week old"` when stale.
    public var staleLabel: String? { isStale && hasBalance ? "Over a week old" : nil }

    /// The row's owner action.
    public var updateLabel: String { hasBalance ? "Update balance" : "Add balance" }

    /// The amount the Update balance form starts from: the balance as plain digits, or empty.
    public var balanceDraftText: String { balance.map(MoneyFormat.plain) ?? "" }
}

/// The names a bank account goes by on every screen (Cash, Activity's account filter).
public enum BankAccountLabel {
    public static func kindAndRef(kind: String, accountRef: String?) -> String {
        let label = BankAccountKind(rawValue: kind)?.label ?? kind.capitalized
        guard let ref = accountRef, !ref.isEmpty else { return "\(label) account" }
        return "\(label) ··· \(ref)"
    }

    public static func title(kind: String, nickname: String?, accountRef: String?) -> String {
        if let nickname, !nickname.isEmpty { return nickname }
        return kindAndRef(kind: kind, accountRef: accountRef)
    }
}

/// Dates on the Cash screen, in Dubai.
public enum CashText {
    /// `"As of today, 14:05"`, `"As of yesterday, 09:10"`, `"As of 3 days ago"` (up to 6),
    /// then `"As of 6 Oct"` (with the year outside this one).
    public static func asOf(_ date: Date, now: Date = .now) -> String { "As of \(relative(date, now: now))" }

    /// `"today, 14:05"`, `"yesterday, 09:10"`, `"3 days ago"` (up to 6), then `"6 Oct"`.
    public static func relative(_ date: Date, now: Date = .now) -> String {
        let today = LedgerDates.today(now: now)
        let day = CalendarDay(date: date)
        let days = day.days(until: today)
        switch days {
        case ...0: return "today, \(LedgerDates.timeLabel(date))"
        case 1: return "yesterday, \(LedgerDates.timeLabel(date))"
        case 2...6: return "\(days) days ago"
        default: return LedgerDates.dayLabel(day, today: today)
        }
    }
}
