import Foundation

/// The SMS path alone — what the outbox and the App Intent need. Kept narrow so
/// the intent's code path can be driven by a stub in `swift test`.
public protocol SMSIngestAPI: Sendable {
    /// `rpc('ingest_sms')`. Idempotent per `client_msg_id`.
    func ingestSMS(profileCode: String, messages: [SMSPayload]) async throws -> [SMSIngestResult]
}

/// Everything the app reads and writes. Every money figure comes from the
/// server; screens render it and never re-derive it.
public protocol LedgerAPI: SMSIngestAPI {
    // Identity
    func profiles() async throws -> [LedgerProfile]
    func memberships() async throws -> [ProfileMembership]
    func createProfile(key: String, name: String) async throws -> String

    // Analytics (SQL RPCs)
    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend]
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup) async throws -> [SpendPoint]
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend]
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle]
    func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus]
    func recurringList(profileCode: String) async throws -> [RecurringCharge]
    func filterMeta(profileCode: String) async throws -> FilterMeta

    // Tables / views
    /// One page of `v_transactions`, newest first, with the exact total.
    func transactions(profileCode: String, query: ActivityQuery, page: PageRequest) async throws -> TransactionPage
    /// The given rows of `v_transactions` (any order): re-reads rows after an edit.
    func transactions(profileCode: String, codes: [String]) async throws -> [LedgerTransaction]
    func insights(profileCode: String) async throws -> [Insight]
    func dismissInsight(insightCode: String) async throws
    /// One page of uploads, newest first, with the exact total.
    func documents(profileCode: String, page: PageRequest) async throws -> ListPage<DocumentRecord>

    // Review (match_reviews)
    /// One page of open reviews (newest first) with what the screen needs to
    /// describe them, and the exact number of open reviews.
    func reviewInbox(profileCode: String, page: PageRequest) async throws -> ReviewInbox
    /// `rpc('resolve_review')`; returns the server's `outcome`. `.retryWithAI`
    /// goes to `retrySMSFallback` and returns `"retrying"`.
    func resolveReview(reviewCode: String, action: ReviewAction) async throws -> String
    /// `rpc('retry_sms_fallback')`: closes an open `unparsed_sms` review and
    /// queues the message for the LLM fallback again.
    func retrySMSFallback(reviewCode: String) async throws

    // Writes
    func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse

    /// Fires whenever a row the screens show changes (transactions, SMS,
    /// documents, insights) for the profile. Ends when the caller stops iterating.
    func changes(profileCode: String) -> AsyncStream<LedgerChange>
}

extension LedgerAPI {
    /// The newest uploads, first page only.
    public func documents(profileCode: String, limit: Int) async throws -> [DocumentRecord] {
        try await documents(profileCode: profileCode, page: PageRequest(offset: 0, limit: limit)).items
    }

    /// The first page of open reviews.
    public func reviewInbox(profileCode: String) async throws -> ReviewInbox {
        try await reviewInbox(profileCode: profileCode, page: PageRequest(offset: 0, limit: ActivityQuery.defaultPageSize))
    }
}

public enum SpendGrain: String, Sendable { case day, week, month }
public enum SpendGroup: String, Sendable { case none, category, merchant, account, card }

public struct TransactionPage: Sendable, Hashable {
    public let rows: [LedgerTransaction]
    public let total: Int?
    public init(rows: [LedgerTransaction], total: Int?) {
        self.rows = rows
        self.total = total
    }
}

public struct LedgerChange: Sendable, Hashable {
    public let table: String
    public init(table: String) { self.table = table }
}

public struct UploadFile: Sendable, Hashable {
    public let filename: String
    public let data: Data
    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}

/// Errors the UI and the outbox act on. Anything else is shown as-is.
public enum LedgerAPIError: Error, Equatable, CustomStringConvertible {
    case notSignedIn
    case noProfile
    case network(String)
    case server(status: Int?, code: String?, message: String)

    /// How the outbox (and the share queue) should treat a failure.
    public enum Kind: Sendable, Equatable {
        /// Will likely pass on its own: offline, timeouts, 5xx, a busy database.
        case transient
        /// Will fail the same way every time: no permission, invalid input, a contract error.
        case permanent
        /// Needs the user to sign in again; not the message's fault.
        case signedOut
    }

    public var description: String {
        switch self {
        case .notSignedIn: "You are signed out."
        case .noProfile: "Choose a ledger first."
        case .network: "No connection to Ledger."
        case let .server(status, code, message):
            if Self.isPermission(status: status, code: code) {
                "You don't have permission to change this ledger (only owners can)."
            } else {
                message
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .notSignedIn: .signedOut
        case .noProfile: .permanent
        case .network: .transient
        case let .server(status, code, _): Self.classify(status: status, code: code)
        }
    }

    /// Worth retrying later without user action.
    public var isTransient: Bool { kind == .transient }

    /// `42501` (insufficient privilege, e.g. a viewer calling `ingest_sms`) or HTTP 403.
    public var isPermission: Bool {
        if case let .server(status, code, _) = self { return Self.isPermission(status: status, code: code) }
        return false
    }

    static func isPermission(status: Int?, code: String?) -> Bool {
        code == "42501" || status == 403
    }

    /// SQLSTATE / PostgREST code first (PostgREST errors carry no HTTP status
    /// through supabase-swift), then the HTTP status. Unknown failures count as
    /// transient; the outbox's attempt cap stops them retrying forever.
    static func classify(status: Int?, code: String?) -> Kind {
        if isPermission(status: status, code: code) { return .permanent }
        if let code, !code.isEmpty {
            if code.hasPrefix("PGRST") {
                switch code {
                case "PGRST000", "PGRST001", "PGRST002", "PGRST003": return .transient   // pool / connection
                case let c where c.hasPrefix("PGRST3"): return .signedOut                  // JWT
                default: return .permanent                                                 // request / schema
                }
            }
            if code.count == 5 {
                let sqlClass = String(code.prefix(2))
                switch sqlClass {
                // connection, transaction rollback (deadlock / serialization),
                // insufficient resources, operator intervention (57014 timeout), system error
                case "08", "40", "53", "57", "58": return .transient
                case "55": return code == "55P03" ? .transient : .permanent              // lock not available
                // data exception (22023 invalid parameter), integrity, syntax/access,
                // raise_exception / no_data_found, invalid authorization
                case "22", "23", "42", "P0", "28", "2F", "0A": return .permanent
                default: break
                }
            }
        }
        if let status {
            if status == 401 { return .signedOut }
            if status == 408 || status == 429 || status >= 500 { return .transient }
            if (400..<500).contains(status) { return .permanent }
        }
        return .transient
    }
}
