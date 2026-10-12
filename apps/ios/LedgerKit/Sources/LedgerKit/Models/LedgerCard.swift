import Foundation

/// `public.cards`, enough to name a card for the "Log Card Payment" action.
public struct LedgerCard: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { cardCode }
    public let cardCode: String
    public let accountCode: String
    public let bankCode: String
    public let last4: String
    /// `active` / `replaced` / `closed`.
    public let status: String
    /// The card's name as the phone shows it; payments are matched by it.
    public let walletName: String?

    public init(cardCode: String, accountCode: String, bankCode: String, last4: String, status: String = "active",
                walletName: String? = nil) {
        self.cardCode = cardCode
        self.accountCode = accountCode
        self.bankCode = bankCode
        self.last4 = last4
        self.status = status
        self.walletName = walletName
    }

    /// `"FAB •1234"`, plus `· closed` / `· replaced` when not active.
    public var label: String {
        let base = "\(bankCode) •\(last4)"
        return status == "active" ? base : "\(base) · \(status)"
    }
}

/// The rules `cards.wallet_name` enforces, checked before the write so the
/// form can say what's wrong: trimmed, 1–64 characters, or empty to clear.
public enum WalletName {
    public static let limit = 64

    /// The value to store: trimmed, inner whitespace collapsed; nil clears it.
    public static func normalise(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// An error sentence, or nil when `raw` can be saved.
    public static func validate(_ raw: String) -> String? {
        guard let name = normalise(raw) else { return nil }
        return name.count > limit ? "Use at most \(limit) characters." : nil
    }

    /// The sentence for a failed save.
    public static func errorMessage(_ error: any Error) -> String {
        if case .server(_, let code, _)? = error as? LedgerAPIError, code == "23505" {
            return "Another card in this ledger already has that name."
        }
        if case .server(_, let code, _)? = error as? LedgerAPIError, code == "23514" {
            return "Use 1 to \(limit) characters, without spaces at either end."
        }
        return (error as? LedgerAPIError)?.description ?? error.localizedDescription
    }
}
