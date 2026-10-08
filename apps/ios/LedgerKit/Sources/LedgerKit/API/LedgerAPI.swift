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
    func transactions(profileCode: String, query: ActivityQuery) async throws -> TransactionPage
    func insights(profileCode: String) async throws -> [Insight]
    func dismissInsight(insightCode: String) async throws
    func documents(profileCode: String, limit: Int) async throws -> [DocumentRecord]

    // Writes
    func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse

    /// Fires whenever a row the screens show changes (transactions, SMS,
    /// documents, insights) for the profile. Ends when the caller stops iterating.
    func changes(profileCode: String) -> AsyncStream<LedgerChange>
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

    public var description: String {
        switch self {
        case .notSignedIn: "You are signed out."
        case .noProfile: "Choose a profile first."
        case .network: "No connection to Ledger."
        case let .server(_, _, message): message
        }
    }

    /// Worth retrying later without user action.
    public var isTransient: Bool {
        switch self {
        case .network: true
        case let .server(status, _, _): status.map { $0 >= 500 || $0 == 429 || $0 == 408 } ?? true
        case .notSignedIn, .noProfile: false
        }
    }
}
