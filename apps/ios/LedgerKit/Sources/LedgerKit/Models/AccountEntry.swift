import Foundation

/// A deposit or withdrawal typed on an account no SMS or statement reaches (a broker's cash),
/// for `add_account_entry`. Notes post their own purchases and payments.
public struct AccountEntryDraft: Identifiable, Sendable, Hashable {
    public enum Direction: String, CaseIterable, Identifiable, Sendable {
        case credit, debit
        public var id: String { rawValue }
        public var label: String { self == .credit ? "Deposit" : "Withdrawal" }
    }

    public struct Submission: Sendable, Hashable {
        public let accountCode: String
        public let direction: Direction
        /// Plain digits, at most 2 decimals.
        public let amount: String
        public let entryDate: CalendarDay
        public let description: String?
    }

    public let id = UUID()
    public let accountCode: String
    public let currency: String
    /// `"SWQ · Swissquote"`: the sheet's subtitle.
    public let accountTitle: String
    public var direction: Direction = .credit
    public var amount = ""
    public var date: CalendarDay
    public var description = ""

    public init(account: BankAccountBalance, today: CalendarDay) {
        accountCode = account.accountCode
        currency = account.currency
        accountTitle = "\(account.bankCode) · \(account.title)"
        date = today
    }

    public static let title = "Add a deposit or withdrawal"
    public static let explanation = "Money in or out that no alert or statement brings in. Notes post their own purchases and payments."
    public var amountLabel: String { "Amount (\(currency))" }

    /// Nil when it can be saved, else the sentence the form shows.
    public func validate(today: CalendarDay) -> String? {
        guard let value = LedgerDecimal.clean(amount),
              value.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let d = LedgerDecimal.parse(value), d > 0 else {
            return "Enter the amount, e.g. 25000 or 25,000.50."
        }
        if date > today { return "The date can't be in the future." }
        if description.count > 80 { return "Keep the description to 80 characters." }
        return nil
    }

    /// The RPC's arguments; nil while `validate` finds a problem.
    public func submission(today: CalendarDay) -> Submission? {
        guard validate(today: today) == nil, let value = LedgerDecimal.clean(amount) else { return nil }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return Submission(accountCode: accountCode, direction: direction, amount: value, entryDate: date,
                          description: text.isEmpty ? nil : text)
    }

    /// `"Deposit added: USD 25,000.00."`
    public var savedMessage: String {
        let value = LedgerDecimal.clean(amount).flatMap(LedgerDecimal.parse).map { MoneyFormat.amount($0, currency: currency) } ?? amount
        return "\(direction.label) added: \(value)."
    }
}
