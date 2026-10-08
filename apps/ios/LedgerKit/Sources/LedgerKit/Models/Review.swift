import Foundation

/// `public.match_reviews` — something the matcher could not decide alone.
public struct MatchReview: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { reviewCode }
    public let reviewCode: String
    public let accountCode: String?
    /// statement_line | sms | transaction | statement
    public let subjectType: String
    public let subjectCode: String
    /// ambiguous | low_score | amount_drift | orphaned | missing_from_statement |
    /// period_overlap | unknown_card | unparsed_sms
    public let reason: String
    public let candidates: [Candidate]
    public let createdAt: Date

    /// One element of `candidates`: a transaction (with a score) for match
    /// reviews, `{bank_code, last4}` for an unknown card, a template for an
    /// unparsed SMS. Every key is optional.
    public struct Candidate: Decodable, Sendable, Hashable {
        public let txnCode: String?
        public let bankCode: String?
        public let last4: String?
        public let templateCode: String?
    }

    enum CodingKeys: String, CodingKey {
        case reviewCode, accountCode, subjectType, subjectCode, reason, candidates, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewCode = try c.decode(String.self, forKey: .reviewCode)
        accountCode = try c.decodeIfPresent(String.self, forKey: .accountCode)
        subjectType = try c.decode(String.self, forKey: .subjectType)
        subjectCode = try c.decode(String.self, forKey: .subjectCode)
        reason = try c.decode(String.self, forKey: .reason)
        candidates = (try? c.decodeIfPresent([Candidate].self, forKey: .candidates)) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public init(reviewCode: String, accountCode: String? = nil, subjectType: String, subjectCode: String,
                reason: String, candidates: [Candidate] = [], createdAt: Date = Date()) {
        self.reviewCode = reviewCode
        self.accountCode = accountCode
        self.subjectType = subjectType
        self.subjectCode = subjectCode
        self.reason = reason
        self.candidates = candidates
        self.createdAt = createdAt
    }
}

/// The parsed fields of an SMS under review. The body is never fetched.
public struct ReviewSMS: Decodable, Sendable, Hashable {
    public let smsCode: String
    public let bankCode: String?
    public let cardLast4: String?
    public let amount: Decimal?
    public let currency: String?
    public let merchantRaw: String?
    public let receivedAt: Date

    public init(smsCode: String, bankCode: String?, cardLast4: String?, amount: Decimal?, currency: String?,
                merchantRaw: String?, receivedAt: Date) {
        self.smsCode = smsCode
        self.bankCode = bankCode
        self.cardLast4 = cardLast4
        self.amount = amount
        self.currency = currency
        self.merchantRaw = merchantRaw
        self.receivedAt = receivedAt
    }
}

/// A statement line under review.
public struct ReviewLine: Decodable, Sendable, Hashable {
    public let lineCode: String
    public let txnDate: CalendarDay
    public let description: String
    public let amountOriginal: Decimal
    public let currencyOriginal: String
    public let direction: String
    public let cardLast4: String?
}

/// `public.accounts`, enough to register an unknown card.
public struct LedgerAccount: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { accountCode }
    public let accountCode: String
    public let bankCode: String
    public let nickname: String?
    public let productName: String?

    public init(accountCode: String, bankCode: String, nickname: String? = nil, productName: String? = nil) {
        self.accountCode = accountCode
        self.bankCode = bankCode
        self.nickname = nickname
        self.productName = productName
    }

    public var title: String { nickname ?? productName ?? bankCode }
}

/// Everything the Review screen shows, fetched together.
public struct ReviewInbox: Sendable, Hashable {
    public let reviews: [MatchReview]
    public let sms: [String: ReviewSMS]
    public let lines: [String: ReviewLine]
    public let transactions: [String: LedgerTransaction]
    public let accounts: [LedgerAccount]

    public init(reviews: [MatchReview], sms: [String: ReviewSMS] = [:], lines: [String: ReviewLine] = [:],
                transactions: [String: LedgerTransaction] = [:], accounts: [LedgerAccount] = []) {
        self.reviews = reviews
        self.sms = sms
        self.lines = lines
        self.transactions = transactions
        self.accounts = accounts
    }
}

/// What the user answers on a review: `resolve_review`'s `p_action`, or
/// `retryWithAI` (`rpc('retry_sms_fallback')`, unparsed SMS only).
public enum ReviewAction: Sendable, Hashable {
    case link(txnCode: String)
    case createNew
    case dismiss
    case registerCard(accountCode: String)
    /// `{"not_a_transaction": true}` — exactly that (with `dismiss` the server
    /// would only dismiss). SMS subjects; outcome `ignored`.
    case notATransaction
    /// Ask the LLM fallback to read an unparsed SMS again.
    case retryWithAI
}
