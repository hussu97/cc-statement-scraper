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
    func reviewInbox(profileCode: String, page: PageRequest) async throws -> ReviewInbox {
        count("reviewInbox")
        let slice = Array(inbox.reviews.dropFirst(page.offset).prefix(page.limit))
        return ReviewInbox(reviews: slice, sms: inbox.sms, lines: inbox.lines, transactions: inbox.transactions,
                           accounts: inbox.accounts, total: inbox.reviews.count)
    }
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

    // MARK: Screens (paging, months, refresh fan-out)

    private var _counts: [String: Int] = [:]
    /// How many times each read was called.
    func calls(_ name: String) -> Int { lock.withLock { _counts[name, default: 0] } }
    private func count(_ name: String) { lock.withLock { _counts[name, default: 0] += 1 } }

    /// `v_transactions` per profile, newest first; pages are sliced from it.
    var transactionRows: [String: [LedgerTransaction]] = [:]
    private(set) var transactionRequests: [(query: ActivityQuery, page: PageRequest)] = []
    private(set) var recategorised: [(txn: String, category: String, merchant: Bool)] = []
    /// `filter_meta.date_range.min`.
    var firstTransactionDay: CalendarDay?
    /// Months `overview` was asked for (nil: current).
    private(set) var overviewMonths: [CalendarDay?] = []
    var overviewFixture: Overview?

    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview {
        lock.withLock { overviewMonths.append(month) }
        count("overview")
        guard let overviewFixture else { throw LedgerAPIError.noProfile }
        return overviewFixture
    }
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend] {
        count("categoryBreakdown")
        return []
    }
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup) async throws -> [SpendPoint] { [] }
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] { [] }
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] {
        count("statementCycles")
        return []
    }
    private(set) var budgetMonths: [CalendarDay?] = []
    func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus] {
        lock.withLock { budgetMonths.append(month) }
        return []
    }
    func recurringList(profileCode: String) async throws -> [RecurringCharge] { [] }
    func filterMeta(profileCode: String) async throws -> FilterMeta {
        FilterMeta(accounts: [], cards: [], categories: [], banks: [],
                   dateRange: FilterMeta.DateRange(min: firstTransactionDay, max: nil))
    }
    func transactions(profileCode: String, query: ActivityQuery, page: PageRequest) async throws -> TransactionPage {
        count("transactions")
        let all = lock.withLock {
            transactionRequests.append((query, page))
            return transactionRows[profileCode] ?? []
        }
        let matching = all.filter { query.keeps(categoryCode: $0.categoryCode) }
        return .init(rows: Array(matching.dropFirst(page.offset).prefix(page.limit)), total: matching.count)
    }
    func transactions(profileCode: String, codes: [String]) async throws -> [LedgerTransaction] {
        count("transactionsByCode")
        let all = lock.withLock { transactionRows[profileCode] ?? [] }
        return all.filter { codes.contains($0.txnCode) }
    }
    func insights(profileCode: String) async throws -> [Insight] { [] }
    func dismissInsight(insightCode: String) async throws {}
    var documentRows: [DocumentRecord] = []
    func documents(profileCode: String, page: PageRequest) async throws -> ListPage<DocumentRecord> {
        count("documents")
        return ListPage(items: Array(documentRows.dropFirst(page.offset).prefix(page.limit)), total: documentRows.count)
    }
    func setTransactionCategory(txnCode: String, categoryCode: String, applyToMerchant: Bool) async throws {
        lock.withLock { recategorised.append((txnCode, categoryCode, applyToMerchant)) }
    }
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse { .init(uploads: []) }
    /// Realtime: each subscription gets the next scripted change list, then
    /// ends (a failed or dropped subscription). Past the script it stays open.
    var changeScript: [[String]] = []
    private(set) var subscriptions = 0
    private var openStreams: [AsyncStream<LedgerChange>.Continuation] = []
    func changes(profileCode: String) -> AsyncStream<LedgerChange> {
        let script: [String]? = lock.withLock {
            defer { subscriptions += 1 }
            return subscriptions < changeScript.count ? changeScript[subscriptions] : nil
        }
        guard let script else {   // stays open until the subscriber stops
            return AsyncStream { continuation in lock.withLock { openStreams.append(continuation) } }
        }
        return AsyncStream { continuation in
            for table in script { continuation.yield(LedgerChange(table: table)) }
            continuation.finish()
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
