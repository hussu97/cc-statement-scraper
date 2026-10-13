import Foundation
import Supabase

/// One card payment as `ingest_wallet_transactions` takes it, from a Shortcuts
/// Transaction automation ("When I tap" a card). Like `SMSPayload`, the
/// `clientMsgId` is minted once on the device and reused by every retry, which
/// makes delivery idempotent. The amount is a `Decimal` and crosses the wire as
/// a decimal string (CLAUDE.md §1.3).
public struct WalletPayment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { clientMsgId }
    public let clientMsgId: UUID
    public let occurredAt: Date
    public let amount: Decimal
    public let currency: String
    public let merchant: String
    /// The card's name as the phone shows it; the server matches it to
    /// `cards.wallet_name` (case-insensitive).
    public let passName: String

    public init(clientMsgId: UUID = UUID(), occurredAt: Date, amount: Decimal, currency: String,
                merchant: String, passName: String) {
        self.clientMsgId = clientMsgId
        self.occurredAt = occurredAt
        self.amount = amount
        self.currency = currency
        self.merchant = merchant
        self.passName = passName
    }

    /// The jsonb element `ingest_wallet_transactions` expects. The amount is a
    /// JSON string (`"12.50"`); a JSON number is refused as `invalid_amount`.
    var json: AnyJSON {
        .object([
            "client_msg_id": .string(clientMsgId.uuidString.lowercased()),
            "occurred_at": .string(LedgerDates.isoTimestamp(occurredAt)),
            "amount": .string(MoneyFormat.plain(amount)),
            "currency": .string(currency),
            "merchant": .string(merchant),
            "pass_name": .string(passName),
        ])
    }

    /// `"AED 12.50 at Carrefour"`: the Settings preview of a payment that
    /// stopped retrying. Shown on the phone only, never logged.
    public var summary: String { "\(currency) \(MoneyFormat.plain(amount)) at \(merchant)" }

    // Persisted in the outbox file with the amount as a string, so it never
    // passes through a binary float.
    enum CodingKeys: String, CodingKey { case clientMsgId, occurredAt, amount, currency, merchant, passName }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientMsgId = try c.decode(UUID.self, forKey: .clientMsgId)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        amount = try c.decode(Decimal.self, forKey: .amount)   // DecimalValue: string or number
        currency = try c.decode(String.self, forKey: .currency)
        merchant = try c.decode(String.self, forKey: .merchant)
        passName = try c.decode(String.self, forKey: .passName)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientMsgId, forKey: .clientMsgId)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(MoneyFormat.plain(amount), forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(merchant, forKey: .merchant)
        try c.encode(passName, forKey: .passName)
    }
}

/// The checks "Log Card Payment" runs before anything leaves the phone. They
/// mirror `private.wallet_input_problem` on the server, so a payment the server
/// would refuse is reported in Shortcuts at once instead of parking later.
public enum WalletCapture {
    public static let merchantLimit = 200
    public static let passNameLimit = 64
    /// `numeric(14,2)`: twelve integer digits.
    static let maxAmount = Decimal(string: "999999999999.99", locale: Locale(identifier: "en_US_POSIX"))!

    public enum Problem: String, Error, Sendable, Equatable {
        case invalidAmount = "invalid_amount"
        /// Device-only: neither Amount was passed (the server never sees it).
        case missingAmount = "missing_amount"
        case invalidCurrency = "invalid_currency"
        /// Device-only: the amount has a currency symbol or word that isn't
        /// exactly one currency. *Currency if missing* never overrides it.
        case ambiguousCurrency = "ambiguous_currency"
        case missingMerchant = "missing_merchant"
        case missingCard = "missing_card"

        /// Shown by Shortcuts. Never echoes the merchant.
        public var userMessage: String {
            switch self {
            case .invalidAmount: "Not logged: the amount must be a number above zero."
            case .missingAmount: "Not logged: the amount is empty. Pass the automation's Amount."
            case .invalidCurrency: "Not logged: the amount has no currency. Set Currency if missing (e.g. AED) in the shortcut."
            case .ambiguousCurrency:
                "Not logged: Bank Ledger can't tell which currency the amount's symbol stands for, and won't guess. Currency if missing applies only to an amount without one."
            case .missingMerchant: "Not logged: the merchant is empty. Pass the automation's Merchant."
            case .missingCard: "Not logged: the card is empty. Pass the automation's Card or Pass."
            }
        }
    }

    /// Builds the ingest payload, or the problem that stops it. Trims and
    /// collapses whitespace, caps lengths, uppercases the currency and rounds
    /// the amount half-up to cents (as the server stores it).
    public static func payment(amount: Decimal, currency: String, merchant: String, passName: String,
                               occurredAt: Date = Date(), clientMsgId: UUID = UUID()) -> Result<WalletPayment, Problem> {
        let cents = MoneyFormat.rounded(amount, scale: 2)
        guard cents > 0, cents <= maxAmount else { return .failure(.invalidAmount) }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            return .failure(.invalidCurrency)
        }
        let cleanMerchant = clean(merchant, limit: merchantLimit)
        guard !cleanMerchant.isEmpty else { return .failure(.missingMerchant) }
        let cleanPass = clean(passName, limit: passNameLimit)
        guard !cleanPass.isEmpty else { return .failure(.missingCard) }
        return .success(WalletPayment(clientMsgId: clientMsgId, occurredAt: occurredAt, amount: cents,
                                      currency: code, merchant: cleanMerchant, passName: cleanPass))
    }

    /// Trimmed, inner whitespace runs collapsed to one space, at most `limit` characters.
    static func clean(_ raw: String, limit: Int) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}
