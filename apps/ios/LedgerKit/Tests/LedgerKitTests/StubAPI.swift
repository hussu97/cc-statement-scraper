import Foundation
@testable import LedgerKit

/// A scripted `LedgerAPI`. Only the SMS path is configurable; everything else
/// returns empty data, which is all the tests that use it need.
final class StubAPI: LedgerAPI, @unchecked Sendable {
    enum IngestBehaviour {
        case succeed(status: String)
        case fail(LedgerAPIError)
        /// Decide per call (profile, messages): return results or throw.
        case custom(@Sendable (String, [SMSPayload]) throws -> [SMSIngestResult])
    }

    private let lock = NSLock()
    private var _behaviour: IngestBehaviour
    private var _calls: [(profile: String, messages: [SMSPayload])] = []

    init(_ behaviour: IngestBehaviour = .succeed(status: "new")) {
        _behaviour = behaviour
    }

    var behaviour: IngestBehaviour {
        get { lock.withLock { _behaviour } }
        set { lock.withLock { _behaviour = newValue } }
    }

    var calls: [(profile: String, messages: [SMSPayload])] { lock.withLock { _calls } }
    var sentMessageCount: Int { calls.reduce(0) { $0 + $1.messages.count } }

    func ingestSMS(profileCode: String, messages: [SMSPayload]) async throws -> [SMSIngestResult] {
        let behaviour: IngestBehaviour = lock.withLock {
            _calls.append((profileCode, messages))
            return _behaviour
        }
        switch behaviour {
        case .succeed(let status):
            return messages.map {
                SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: "sms_x", status: status, txnCode: nil)
            }
        case .fail(let error):
            throw error
        case .custom(let decide):
            return try decide(profileCode, messages)
        }
    }

    var inbox = ReviewInbox(reviews: [])
    private(set) var resolved: [(String, ReviewAction)] = []
    func reviewInbox(profileCode: String) async throws -> ReviewInbox { inbox }
    func resolveReview(reviewCode: String, action: ReviewAction) async throws -> String {
        lock.withLock { resolved.append((reviewCode, action)) }
        if let resolveError { throw resolveError }
        return "dismissed"
    }
    var resolveError: LedgerAPIError?
    private(set) var retried: [String] = []
    func retrySMSFallback(reviewCode: String) async throws {
        lock.withLock { retried.append(reviewCode) }
    }

    // MARK: Unused by these tests

    /// Thrown by `profiles()` when set (a session the server no longer accepts).
    var profilesError: LedgerAPIError?
    func profiles() async throws -> [LedgerProfile] {
        if let profilesError { throw profilesError }
        return []
    }
    func memberships() async throws -> [ProfileMembership] { [] }
    func createProfile(key: String, name: String) async throws -> String { "prf_x" }
    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview { throw LedgerAPIError.noProfile }
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend] { [] }
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup) async throws -> [SpendPoint] { [] }
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] { [] }
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] { [] }
    func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus] { [] }
    func recurringList(profileCode: String) async throws -> [RecurringCharge] { [] }
    func filterMeta(profileCode: String) async throws -> FilterMeta {
        FilterMeta(accounts: [], cards: [], categories: categoryOptions, banks: [], dateRange: nil)
    }
    func transactions(profileCode: String, query: ActivityQuery) async throws -> TransactionPage { .init(rows: [], total: 0) }
    func insights(profileCode: String) async throws -> [Insight] { [] }
    func dismissInsight(insightCode: String) async throws {}
    func documents(profileCode: String, limit: Int) async throws -> [DocumentRecord] { [] }
    func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws {}
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse {
        var items: [UploadResponse.Item] = []
        for file in files { items += try uploadFile(file).uploads }
        return UploadResponse(uploads: items)
    }
    func changes(profileCode: String) -> AsyncStream<LedgerChange> { AsyncStream { $0.finish() } }

    // MARK: Statement detail, spend split, banks, upload timeline

    var detail: StatementDetail?
    var detailError: LedgerAPIError?
    var breakdown: SpendBreakdown?
    private(set) var breakdownCalls: [SpendSplitGrouping] = []
    var bankRows: [BankInfo] = []
    var transactionsByCode: [String: LedgerTransaction] = [:]
    var categoryOptions: [FilterMeta.CategoryOption] = []
    /// `document_events` the initial fetch returns, by doc code.
    var storedEvents: [String: [DocumentEvent]] = [:]
    /// Per filename: the upload answer, or the error to throw.
    var uploadAnswers: [String: Result<UploadResponse.Item, LedgerAPIError>] = [:]
    private(set) var uploadedFilenames: [String] = []
    /// Events pushed here reach `documentEventStream` subscribers.
    let eventFeed = AsyncStream<DocumentEvent>.makeStream()

    func statementDetail(profileCode: String, stmtCode: String) async throws -> StatementDetail {
        if let detailError { throw detailError }
        guard let detail else { throw LedgerAPIError.server(status: nil, code: "P0002", message: "unknown statement") }
        return detail
    }
    func spendBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay, groupBy: SpendSplitGrouping,
                        topN: Int) async throws -> SpendBreakdown {
        lock.withLock { breakdownCalls.append(groupBy) }
        guard let breakdown else { throw LedgerAPIError.network("offline") }
        return breakdown
    }
    func banks() async throws -> [BankInfo] { bankRows }
    func transaction(profileCode: String, txnCode: String) async throws -> LedgerTransaction? { transactionsByCode[txnCode] }
    func documentEvents(profileCode: String, docCodes: [String]) async throws -> [DocumentEvent] {
        DocumentEvent.ordered(docCodes.flatMap { storedEvents[$0] ?? [] })
    }
    func documentEventStream(profileCode: String) -> AsyncStream<DocumentEvent> { eventFeed.stream }
    func uploadFile(_ file: UploadFile) throws -> UploadResponse {
        lock.withLock { uploadedFilenames.append(file.filename) }
        switch uploadAnswers[file.filename] {
        case .success(let item)?: return UploadResponse(uploads: [item])
        case .failure(let error)?: throw error
        case nil: return UploadResponse(uploads: [])
        }
    }
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_791_436_364)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func temporaryOutboxURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ledger-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("sms-outbox.json")
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

import Testing
