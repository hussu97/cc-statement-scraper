import Foundation

// Where a bank logo replaces the bank code, the text beside it keeps only the
// card: `"•1234"` instead of `"FAB •1234"`. The logo's accessibility label
// carries the bank's name.

extension LedgerTransaction {
    /// `"•1234"`, else the account nickname, else nil (the logo says it all).
    public var cardSuffix: String? {
        if let last4 = cardLast4 { return "•\(last4)" }
        return accountNickname
    }
}

/// The other card of a card transfer: "Paid to" on the paying card's debit, "From" on the
/// paid card's credit. The server pairs them (`private.link_card_transfer`); the app only names it.
public struct CardTransferPeer: Hashable, Sendable {
    public let prefix: String
    public let txnCode: String
    public let bankCode: String
    public let cardSuffix: String?
}

extension LedgerTransaction {
    public var transferPeer: CardTransferPeer? {
        guard let code = transferTxnCode, let bank = transferBankCode else { return nil }
        return CardTransferPeer(prefix: direction == "debit" ? "Paid to" : "From", txnCode: code,
                                bankCode: bank, cardSuffix: transferCardLast4.map { "•\($0)" })
    }
}

extension StatementCycle {
    /// `"•1234"`, else `"Statement"` / `"History extract"`.
    public var cardSuffix: String { cardLast4.map { "•\($0)" } ?? kindLabel }
}

extension Overview.OverviewAccount {
    /// `"•1234, •5678"`, else the account title when it isn't just the bank code.
    public var cardSuffix: String? {
        cardsLabel ?? (title == bankCode ? nil : title)
    }
}

/// An account's display name, as the server makes it (`budget_status.account_name`) and the
/// web's `accountLabel`: the nickname (trimmed, when not blank), else `"BANK · product"`, else the bank.
public enum AccountLabel {
    public static func make(bankCode: String, nickname: String?, productName: String?) -> String {
        if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty { return nick }
        return [bankCode, productName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
