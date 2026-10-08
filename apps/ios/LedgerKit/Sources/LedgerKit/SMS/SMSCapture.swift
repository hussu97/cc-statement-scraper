import Foundation
import Supabase

/// One message as `ingest_sms` takes it. `clientMsgId` is minted once, on the
/// device, when the message is first seen; every retry reuses it, which is what
/// makes delivery idempotent.
public struct SMSPayload: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { clientMsgId }
    public let clientMsgId: UUID
    public let receivedAt: Date
    public let sender: String
    public let body: String

    public init(clientMsgId: UUID = UUID(), receivedAt: Date, sender: String, body: String) {
        self.clientMsgId = clientMsgId
        self.receivedAt = receivedAt
        self.sender = sender
        self.body = body
    }

    /// The jsonb element `ingest_sms` expects. UUIDs go lowercase — Postgres
    /// accepts either, but the result echoes the string we sent and the
    /// outbox matches on it.
    var json: AnyJSON {
        .object([
            "client_msg_id": .string(clientMsgId.uuidString.lowercased()),
            "received_at": .string(LedgerDates.isoTimestamp(receivedAt)),
            "sender": .string(sender),
            "body": .string(body),
        ])
    }
}

/// The on-device filter the App Intent runs before anything leaves the phone.
/// OTPs are never sent; non-credit-card messages are dropped (the product is
/// credit cards only — the server also stores debit/account SMS as `ignored`,
/// but there is no reason to send them).
public enum SMSCapture {
    public enum Decision: Equatable, Sendable {
        case accept
        case dropOTP
        case dropNotCreditCard(reason: String)
        case dropEmpty

        public var isAccepted: Bool { self == .accept }

        /// Shown by Shortcuts after the automation runs. Never echoes the body.
        public var userMessage: String {
            switch self {
            case .accept: "Logged."
            case .dropOTP: "Skipped: one-time passcode."
            case .dropNotCreditCard: "Skipped: not a credit-card transaction."
            case .dropEmpty: "Skipped: empty message."
            }
        }
    }

    // Same alternation as the server's defence-in-depth check in `ingest_sms`.
    static let otpPattern = try! NSRegularExpression(
        pattern: #"\botp\b|one[- ]?time\s+(password|passcode|pin)|verification\s+code|pass\s?code|security\s+code"#,
        options: [.caseInsensitive])

    /// Explicit credit-card wording wins over anything that looks like an account alert.
    static let creditCardPattern = try! NSRegularExpression(
        pattern: #"credit\s*card|\bcr\.?\s*card\b|\bcc\s+(ending|no)|covered\s+card"#,
        options: [.caseInsensitive])

    /// Obvious debit-card / current-account alerts.
    static let accountPattern = try! NSRegularExpression(
        pattern: #"debit\s*card|\bdc\s+ending|\ba/c\b|\bacct?\b\.?\s*(no\.?\s*)?[x*\d]|\baccount\s*(no\.?|number)?\s*[x*\d]{3,}|\bsalary\b|\btransfer(red)?\b|\biban\b|\bcredited\s+to\s+your\s+(a/c|account)"#,
        options: [.caseInsensitive])

    /// A transaction mentions an amount: a currency code or symbol next to a number.
    static let amountPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z]{3}\s?\d[\d,]*(\.\d+)?|\d[\d,]*(\.\d+)?\s?[A-Z]{3}\b|[$€£]\s?\d"#,
        options: [])

    public static func isOTP(_ body: String) -> Bool { matches(otpPattern, body) }

    public static func classify(body: String, sender: String? = nil) -> Decision {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .dropEmpty }
        if isOTP(text) { return .dropOTP }
        if matches(creditCardPattern, text) { return .accept }
        if matches(accountPattern, text) { return .dropNotCreditCard(reason: "account_alert") }
        guard matches(amountPattern, text) else { return .dropNotCreditCard(reason: "no_amount") }
        return .accept
    }

    /// Builds the ingest payload for an accepted message, or nil when the filter drops it.
    public static func payload(body: String, sender: String?, receivedAt: Date = .now,
                               clientMsgId: UUID = UUID()) -> (Decision, SMSPayload?) {
        let decision = classify(body: body, sender: sender)
        guard decision.isAccepted else { return (decision, nil) }
        let cleanSender = (sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (decision, SMSPayload(clientMsgId: clientMsgId, receivedAt: receivedAt,
                                     sender: String(cleanSender.prefix(64)),
                                     body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
