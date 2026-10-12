import Foundation

/// What an outbox entry carries; each kind goes to its own RPC.
public enum OutboxItem: Sendable, Hashable {
    /// A bank SMS for `ingest_sms`.
    case sms(SMSPayload)
    /// A card payment for `ingest_wallet_transactions`.
    case wallet(WalletPayment)

    public enum Kind: String, Codable, Sendable, Hashable, Comparable {
        case sms, wallet
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind {
        switch self {
        case .sms: .sms
        case .wallet: .wallet
        }
    }

    public var clientMsgId: UUID {
        switch self {
        case .sms(let p): p.clientMsgId
        case .wallet(let p): p.clientMsgId
        }
    }

    /// When it happened on the phone: the SMS's arrival or the payment.
    public var capturedAt: Date {
        switch self {
        case .sms(let p): p.receivedAt
        case .wallet(let p): p.occurredAt
        }
    }
}

/// A message or payment waiting to reach the server.
public struct OutboxEntry: Sendable, Hashable, Identifiable {
    public var id: UUID { item.clientMsgId }
    public let item: OutboxItem
    /// The ledger it goes to. Nil while no ledger is known (captured signed
    /// out, or before an owned ledger exists): the entry waits and is never
    /// sent until the "SMS go to" ledger is known, which then adopts it
    /// (BACKLOG IOS-12r). Otherwise reassigned only when the user retries a
    /// parked entry.
    public var profileCode: String?
    public let enqueuedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    /// Set when the entry stopped being retried automatically: a permanent
    /// error (no permission, invalid message), a failing per-message status, or
    /// too many attempts. It then waits in Settings for Retry or Delete and
    /// never blocks the rest of the queue. Absent in files written before
    /// parking existed, which decode as not parked.
    public var parkedAt: Date?
    public var parkedReason: String?

    public init(item: OutboxItem, profileCode: String?, enqueuedAt: Date, attempts: Int = 0, nextAttemptAt: Date,
                lastError: String? = nil, parkedAt: Date? = nil, parkedReason: String? = nil) {
        self.item = item
        self.profileCode = profileCode
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.parkedAt = parkedAt
        self.parkedReason = parkedReason
    }

    public var isParked: Bool { parkedAt != nil }
    /// Waiting for a ledger to be known before it can be sent.
    public var awaitsLedger: Bool { profileCode == nil && !isParked }
    public var kind: OutboxItem.Kind { item.kind }

    /// The SMS, when this entry is one.
    public var sms: SMSPayload? {
        if case .sms(let p) = item { return p }
        return nil
    }

    /// The card payment, when this entry is one.
    public var wallet: WalletPayment? {
        if case .wallet(let p) = item { return p }
        return nil
    }
}

// The file format: `kind` names the item and `payload` holds it. Files written
// before payments existed have no `kind`, and their entries decode as SMS.
extension OutboxEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case kind, payload, profileCode, enqueuedAt, attempts, nextAttemptAt, lastError, parkedAt, parkedReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(OutboxItem.Kind.self, forKey: .kind) ?? .sms {
        case .sms: item = .sms(try c.decode(SMSPayload.self, forKey: .payload))
        case .wallet: item = .wallet(try c.decode(WalletPayment.self, forKey: .payload))
        }
        profileCode = try c.decodeIfPresent(String.self, forKey: .profileCode)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        attempts = try c.decode(Int.self, forKey: .attempts)
        nextAttemptAt = try c.decode(Date.self, forKey: .nextAttemptAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        parkedAt = try c.decodeIfPresent(Date.self, forKey: .parkedAt)
        parkedReason = try c.decodeIfPresent(String.self, forKey: .parkedReason)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch item {
        case .sms(let p): try c.encode(p, forKey: .payload)
        case .wallet(let p): try c.encode(p, forKey: .payload)
        }
        try c.encodeIfPresent(profileCode, forKey: .profileCode)
        try c.encode(enqueuedAt, forKey: .enqueuedAt)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(nextAttemptAt, forKey: .nextAttemptAt)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(parkedAt, forKey: .parkedAt)
        try c.encodeIfPresent(parkedReason, forKey: .parkedReason)
    }
}
