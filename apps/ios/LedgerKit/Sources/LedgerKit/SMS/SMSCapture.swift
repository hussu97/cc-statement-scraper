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
/// It drops only what must never leave it: one-time passcodes, and empty input.
/// Everything else is sent and classified on the server (`process_sms`): the
/// bank templates file debit-card and account alerts as `ignored`, and an
/// unknown format is kept as `unparsed` for the LLM fallback. A guess made here
/// was lost for good when it was wrong, so the phone no longer guesses.
public enum SMSCapture {
    public enum Decision: Equatable, Sendable {
        case accept
        case dropOTP
        case dropEmpty

        public var isAccepted: Bool { self == .accept }

        /// Shown by Shortcuts after the automation runs. Never echoes the body.
        public var userMessage: String {
            switch self {
            case .accept: "Logged."
            case .dropOTP: "Skipped: one-time passcode."
            case .dropEmpty: "Skipped: empty message."
            }
        }
    }

    /// The OTP pattern, character for character the server's `private.sms_otp_pattern()`
    /// (`ingest_sms` drops OTPs again with it). It uses only syntax that ICU and Postgres read
    /// the same way (no `\b`, `\d`, `\s` or `.`), and both match it case-insensitively.
    /// `SMSOTPParityTests` pins it to the fixture shared with pgTAP
    /// (`supabase/tests/38_sms_otp_filter.test.sql`), which also lists every server SMS template
    /// example as a message that must be sent: change all three together.
    static let otpPatternSource: String =
        // "OTP" as a word; `_` counts as part of a word, as in `\b`, so "dropped_otp" is not one.
        #"(^|[^a-zA-Z0-9_])otp([^a-zA-Z_]|$)"#
        + #"|one[^a-zA-Z0-9]{0,3}time[^a-zA-Z0-9]{0,3}(password|pin|code)"#
        + #"|verification[^a-zA-Z0-9]{0,3}(code|pin)"#
        + #"|pass[^a-zA-Z0-9]?code"#
        + #"|security[^a-zA-Z0-9]{0,3}code"#
        + #"|authentication[^a-zA-Z0-9]{0,3}(code|pin|password)"#
        + #"|secure[^a-zA-Z0-9]{0,3}code"#
        + #"|3[^a-zA-Z0-9]?d[^a-zA-Z0-9]?secure[^a-zA-Z0-9]{1,3}(password|pin)"#
        // "Use 482913 as the code…", "482913 is your one-time password"
        + #"|(^|[^a-zA-Z0-9.,])[0-9]{4,8}[^a-zA-Z0-9]{1,3}(is|as)[^a-zA-Z0-9]{1,3}(your|the)[^a-zA-Z0-9]{1,3}"#
        + #"([a-zA-Z-]{1,20}[^a-zA-Z0-9]{1,3}){0,3}(code|pin|password|passcode)([^a-zA-Z]|$)"#
        // "Never share this code", "Do not share your OTP"
        + #"|(do[^a-zA-Z0-9]{1,3}not|don[^a-zA-Z0-9]{0,2}t|never)[^a-zA-Z0-9]{1,3}share[^a-zA-Z0-9]{1,3}"#
        + #"((this|the|your|it)[^a-zA-Z0-9]{1,3})?(otp|code|password|passcode)"#
        // Arabic: verification code, passcode, password, secret word, one-time.
        + #"|رمز (ال)?تحقق|رمز (ال)?مرور|كلمة (ال)?مرور|كلمة (ال)?سر|لمرة واحدة"#

    static let otpPattern = try! NSRegularExpression(pattern: otpPatternSource, options: [.caseInsensitive])

    public static func isOTP(_ body: String) -> Bool { matches(otpPattern, body) }

    public static func classify(body: String, sender: String? = nil) -> Decision {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .dropEmpty }
        if isOTP(text) { return .dropOTP }
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
