import Foundation

/// The Update balance form: the amount stays the text the person typed and goes to
/// `record_balance` as a decimal string (CLAUDE.md §1.3). Same shape the server checks:
/// up to 12 digits, an optional minus (an overdrawn account), at most two decimals.
public struct UpdateBalanceDraft: Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let currency: String
    /// `"ADCB · Salary account"`: the sheet's heading.
    public let accountTitle: String
    public var amount: String

    public init(accountCode: String, currency: String = "AED", accountTitle: String, amount: String = "") {
        self.accountCode = accountCode
        self.currency = currency
        self.accountTitle = accountTitle
        self.amount = amount
    }

    /// Starts from the balance on screen.
    public init(account: BankAccountBalance) {
        self.init(accountCode: account.accountCode, currency: account.currency,
                  accountTitle: "\(account.bankCode) · \(account.title)", amount: account.balanceDraftText)
    }

    /// What is sent: grouping commas and spaces dropped, a typographic minus made ASCII.
    public var normalizedAmount: String {
        amount.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An error sentence, or nil when the draft can be sent.
    public func validate() -> String? {
        Self.isBalance(normalizedAmount) ? nil : "Enter the balance as a number, e.g. 28650.40, or -120 if overdrawn."
    }

    /// `-?digits{1,12}(.d{1,2})?`, as `record_balance` checks it.
    static func isBalance(_ s: String) -> Bool {
        var body = Substring(s)
        if body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...12).contains(parts[0].count),
              parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        if parts.count == 2 {
            return (1...2).contains(parts[1].count) && parts[1].allSatisfy(\.isASCIIDigit)
        }
        return true
    }

    /// The server's refusals in plain words.
    public static func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, _) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return "Only the ledger's owners can update balances." }
        switch code {
        case "22023": return "Enter the balance as a number with at most two decimals."
        case "P0002": return "This account isn't in the ledger any more. Pull to refresh."
        default: return LoadState<Bool>.message(for: error)
        }
    }

    /// `"Balance updated."`
    public static let savedMessage = "Balance updated."
}

/// The Add bank account form: bank, current or savings, the digits the bank's SMS show at the end
/// of the account number (how alerts find the account), and an optional nickname.
public struct AddBankAccountDraft: Sendable, Hashable {
    public var bankCode: String?
    public var kind: BankAccountKind
    public var accountRef: String
    public var nickname: String

    public init(bankCode: String? = nil, kind: BankAccountKind = .current, accountRef: String = "", nickname: String = "") {
        self.bankCode = bankCode
        self.kind = kind
        self.accountRef = accountRef
        self.nickname = nickname
    }

    /// The digits, spaces and the bank's mask dots dropped.
    public var normalizedRef: String {
        accountRef.filter { !$0.isWhitespace && $0 != "·" && $0 != "." && $0 != "*" && $0 != "x" && $0 != "X" }
    }

    /// The nickname, trimmed; nil when blank.
    public var normalizedNickname: String? {
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// An error sentence, or nil when the draft can be sent.
    public func validate() -> String? {
        guard bankCode != nil else { return "Choose the bank." }
        let ref = normalizedRef
        guard (3...12).contains(ref.count), ref.allSatisfy(\.isASCIIDigit) else {
            return "Enter the 3 to 12 digits at the end of the account number, as your bank's SMS show them."
        }
        return nil
    }

    /// The server's refusals in plain words.
    public func message(for error: any Error) -> String {
        guard let api = error as? LedgerAPIError, case let .server(_, code, _) = api else {
            return LoadState<Bool>.message(for: error)
        }
        if api.isPermission { return "Only the ledger's owners can add accounts." }
        switch code {
        case "23505":
            return "The \(bankCode ?? "") account ending \(normalizedRef) is already in this ledger."
        case "22023":
            return "Check the account type and the digits: 3 to 12 from the end of the account number."
        case "P0002":
            return "Bank Ledger doesn't know this bank yet."
        default:
            return LoadState<Bool>.message(for: error)
        }
    }

    /// `"ADCB current account added."`
    public var savedMessage: String { "\(bankCode ?? "Bank") \(kind.rawValue) account added." }

    /// The banks the form offers, by name: the `public.banks` rows when loaded, else the seed's names.
    public static func bankChoices(_ banks: [BankInfo]) -> [BankInfo] {
        let rows = banks.isEmpty
            ? BankDirectory.knownNames.map { BankInfo(bankCode: $0.key, name: $0.value) }
            : banks
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
