import Foundation

/// A bank account shown under Investments: a `savings_account` holding backed by one current or
/// savings account (`track_account_as_investment`). Its value is the account's balance, its money
/// in and out are the account's transfers, and its interest is income that stays in it. The
/// account stays in Accounts, out of the cash total: net worth counts it once, under Investments.
/// Every figure is the server's; this decides what the screens offer and words it.
extension Holding {
    public var isSavingsAccount: Bool { kind == .savingsAccount }

    /// A savings account's stated rate: `"5% a year"`, `"4.25% a year"`; nil without one or for
    /// another kind (a deposit's rate is in its detail line).
    public var savingsRateText: String? {
        guard isSavingsAccount, let ratePct else { return nil }
        return SavingsAccountText.rateAYear(ratePct)
    }

    /// The holding screen's line on how it is valued; nil for other kinds.
    public var valuedByAccountNote: String? {
        guard isSavingsAccount else { return nil }
        return "Valued at its bank account's balance. Transfers into and out of the account are money in and out; its interest stays in it."
    }

    /// The bank account this savings account is shown for, from Accounts' list (`cash_position`
    /// names each account's `investment_holding_code`; `holdings_valuation` doesn't send the
    /// account). Nil for other kinds, or before Accounts has loaded.
    public func bankAccount(in position: CashPosition?) -> BankAccountBalance? {
        guard isSavingsAccount else { return nil }
        return position?.accounts.first { $0.investmentHoldingCode == holdingCode }
    }

    /// What the holding screen offers (`canEdit`: the reader owns the ledger).
    public func actions(canEdit: Bool) -> HoldingActions { HoldingActions(holding: self, canEdit: canEdit) }
}

/// The holding screen's actions. A savings account is edited, valued and fed from its bank
/// account, so it offers only that account and, for owners, counting it as cash again.
public struct HoldingActions: Sendable, Hashable {
    /// The toolbar's Edit (the holding form, with Close).
    public let edit: Bool
    /// Update value or Update price.
    public let recordValue: Bool
    /// Add money in or out by hand.
    public let addFlow: Bool
    /// A row opening the bank account the holding is valued at.
    public let opensBankAccount: Bool
    /// Show as cash instead (closes the holding; the account counts as cash again).
    public let stopShowing: Bool

    public init(holding: Holding, canEdit: Bool) {
        edit = canEdit && holding.kind.isEditable
        recordValue = canEdit && holding.canRecordValue
        addFlow = canEdit && holding.kind.takesFlows
        opensBankAccount = holding.isSavingsAccount
        stopShowing = canEdit && holding.isSavingsAccount
    }
}

/// Words for a savings account shown as an investment.
public enum SavingsAccountText {
    /// `5.000` → `"5% a year"`, `4.25` → `"4.25% a year"`.
    public static func rateAYear(_ pct: Decimal) -> String { HoldingDraft.trimmed(pct, places: 3) + "% a year" }

    /// Accounts' chip on such an account, and the bank account screen's row title.
    public static let chip = "In Investments"
    public static let shownTitle = "Shown under Investments"
    public static let shownNote = "Valued here at this balance; net worth counts it under Investments, not as cash."
    public static let openAccount = "Bank account"
    /// The owner's way back: the holding closes and the account counts as cash.
    public static let stopShowing = "Show as cash instead"
    public static func stopTitle(_ holding: Holding) -> String { "Stop showing \(holding.name) under Investments?" }
    public static let stopMessage =
        "The account stays in Accounts with its transactions, and counts as cash again. You can show it under Investments again from the account."
    public static func stoppedMessage(_ holding: Holding) -> String { "\(holding.name) counts as cash again." }
}

extension BankAccountBalance {
    /// Shown under Investments: left out of Accounts' total, counted with the holdings.
    public var isShownAsInvestment: Bool { investmentHoldingCode != nil }

    /// An owner may show a current or savings account under Investments, once.
    public func canShowAsInvestment(canEdit: Bool) -> Bool {
        canEdit && !isShownAsInvestment && BankAccountKind(rawValue: kind) != nil
    }
}

/// The owner's "Show under Investments" form for one bank account: an optional stated interest
/// rate, as `track_account_as_investment` takes it.
public struct TrackAccountDraft: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let accountTitle: String
    /// Percent a year as typed (`"5"`, `"4.25"`); empty for none.
    public var ratePct: String

    public init(account: BankAccountBalance, ratePct: String = "") {
        accountCode = account.accountCode
        accountTitle = account.title
        self.ratePct = ratePct
    }

    public static let title = "Show under Investments"
    public static let explanation =
        "The account stays in Accounts with its statements and transactions. Under Investments it is valued at its balance: transfers in and out are money in and out, and interest is its return. Net worth counts it there, not as cash."
    public static let rateLabel = "Interest rate"
    public static let ratePlaceholder = "Optional, e.g. 5"
    public static let rateNote = "The rate a year the bank states. It is shown beside the account; returns come from the interest actually paid."

    /// The rate as sent: nil when empty.
    public var normalizedRate: String? {
        let s = HoldingDraft.stripped(ratePct).replacingOccurrences(of: "%", with: "")
        return s.isEmpty ? nil : s
    }

    /// An error sentence, or nil when the draft can be sent.
    public func validate() -> String? {
        guard let rate = normalizedRate else { return nil }
        guard HoldingDraft.isDecimal(rate, integerDigits: 3, fractionDigits: 3),
              let r = LedgerDecimal.parse(rate), r <= 100
        else { return "Enter the interest rate a year in percent, e.g. 5 or 4.25, or leave it empty." }
        return nil
    }

    public var savedMessage: String { "\(accountTitle) is shown under Investments." }

    /// The server's refusals in plain words.
    public static func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, message) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return HoldingDraft.ownerOnlyMessage }
        return code == "22023" ? "Couldn't show it under Investments: \(message)." : LoadState<Bool>.message(for: error)
    }
}
