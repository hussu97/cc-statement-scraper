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

    // MARK: Card payments (same behaviour as SMS unless `walletDecide` is set)

    private var _walletCalls: [(profile: String, items: [WalletPayment])] = []
    var walletCalls: [(profile: String, items: [WalletPayment])] { lock.withLock { _walletCalls } }
    /// Decides a wallet call's answer when set (`.custom` covers SMS only).
    var walletDecide: (@Sendable (String, [WalletPayment]) throws -> [SMSIngestResult])?

    func ingestWalletPayments(profileCode: String, items: [WalletPayment]) async throws -> [SMSIngestResult] {
        let (behaviour, decide) = lock.withLock {
            _walletCalls.append((profileCode, items))
            return (_behaviour, walletDecide)
        }
        if let decide { return try decide(profileCode, items) }
        switch behaviour {
        case .succeed(let status):
            return items.map {
                SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: "sms_w", status: status, txnCode: nil)
            }
        case .fail(let error):
            throw error
        case .custom:
            return items.map {
                SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: "sms_w", status: "created", txnCode: nil)
            }
        }
    }

    /// `public.cards` rows; `cardWriteError` is thrown by `updateCardWalletName` when set.
    var cardRows: [LedgerCard] = []
    var cardWriteError: LedgerAPIError?
    private(set) var walletNameWrites: [(card: String, name: String?)] = []
    func cards(profileCode: String) async throws -> [LedgerCard] {
        count("cards")
        return lock.withLock { cardRows }
    }
    func updateCardWalletName(cardCode: String, name: String?) async throws {
        if let cardWriteError { throw cardWriteError }
        lock.withLock {
            walletNameWrites.append((cardCode, name))
            cardRows = cardRows.map {
                $0.cardCode == cardCode
                    ? LedgerCard(cardCode: $0.cardCode, accountCode: $0.accountCode, bankCode: $0.bankCode, last4: $0.last4,
                                 status: $0.status, walletName: name)
                    : $0
            }
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
        return stubProfiles
    }
    var stubProfiles: [LedgerProfile] = []
    var stubMemberships: [ProfileMembership] = []
    func memberships() async throws -> [ProfileMembership] { stubMemberships }
    func createProfile(key: String, name: String) async throws -> String { "prf_x" }
    /// `list_profile_members`' row count; nil throws (a non-member, offline).
    var memberCountValue: Int? = 1
    func memberCount(profileCode: String) async throws -> Int {
        count("memberCount")
        guard let memberCountValue else { throw LedgerAPIError.network("-1009") }
        return memberCountValue
    }

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
    /// `spend_series` answers (all spend when unset), and the filters it was asked for.
    var seriesPoints: [SpendPoint] = []
    private(set) var seriesFilters: [SpendFilter] = []
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup,
                     filter: SpendFilter) async throws -> [SpendPoint] {
        lock.withLock { seriesFilters.append(filter) }
        return seriesPoints
    }
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] { [] }
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] {
        count("statementCycles")
        return []
    }
    private(set) var budgetMonths: [CalendarDay?] = []
    /// `budget_status` rows, effective and not: like the server, a call without
    /// `p_include_inactive` gets only the effective ones.
    var budgetStatusRows: [BudgetStatus] = []
    private(set) var budgetIncludeInactive: [Bool] = []
    /// Thrown by `saveBudget` / `deleteBudget` when set.
    var budgetWriteError: LedgerAPIError?
    /// Thrown by `filterMeta` when set.
    var filterMetaError: LedgerAPIError?
    private(set) var savedBudgets: [(profile: String, draft: BudgetDraft)] = []
    private(set) var deletedBudgets: [String] = []
    func budgetStatus(profileCode: String, month: CalendarDay?, includeInactive: Bool) async throws -> [BudgetStatus] {
        lock.withLock {
            budgetMonths.append(month)
            budgetIncludeInactive.append(includeInactive)
        }
        count("budgetStatus")
        return includeInactive ? budgetStatusRows : budgetStatusRows.filter(\.isEffective)
    }
    func saveBudget(profileCode: String, draft: BudgetDraft) async throws {
        if let budgetWriteError { throw budgetWriteError }
        lock.withLock { savedBudgets.append((profileCode, draft)) }
    }
    func deleteBudget(budgetCode: String) async throws {
        if let budgetWriteError { throw budgetWriteError }
        lock.withLock { deletedBudgets.append(budgetCode) }
    }
    /// `public.accounts` rows; `accountsError` is thrown by `accounts` when set.
    var accountRows: [LedgerAccount] = []
    var accountsError: LedgerAPIError?
    func accounts(profileCode: String) async throws -> [LedgerAccount] {
        count("accounts")
        if let accountsError { throw accountsError }
        return accountRows
    }
    func recurringList(profileCode: String) async throws -> [RecurringCharge] { [] }
    func filterMeta(profileCode: String) async throws -> FilterMeta {
        if let filterMetaError { throw filterMetaError }
        return FilterMeta(accounts: [], cards: [], categories: categoryOptions, banks: [],
                   dateRange: FilterMeta.DateRange(min: firstTransactionDay, max: nil))
    }
    /// `activity_summary`'s answer, or the error it throws; nil answers zero rows.
    var summaryResult: Result<ActivitySummary, LedgerAPIError>?
    private(set) var summaryQueries: [ActivityQuery] = []
    func activitySummary(profileCode: String, query: ActivityQuery) async throws -> ActivitySummary {
        lock.withLock { summaryQueries.append(query) }
        switch summaryResult {
        case .success(let s)?: return s
        case .failure(let e)?: throw e
        case nil: return ActivitySummary(txnCount: 0, netAed: 0)
        }
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
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse {
        var items: [UploadResponse.Item] = []
        for file in files { items += try uploadFile(file).uploads }
        return UploadResponse(uploads: items)
    }
    /// Realtime: each subscription gets the next scripted change list, then
    /// ends (a failed or dropped subscription). Past the script it stays open.
    var changeScript: [[String]] = []
    private(set) var subscriptions = 0
    private var openStreams: [AsyncStream<LedgerChange>.Continuation] = []
    // MARK: Statement detail, spend split, banks, upload timeline

    var detail: StatementDetail?
    var detailError: LedgerAPIError?
    var breakdown: SpendBreakdown?
    private(set) var breakdownCalls: [SpendSplitGrouping] = []
    private(set) var breakdownFilters: [SpendFilter] = []
    var bankRows: [BankInfo] = []
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
                        topN: Int, filter: SpendFilter) async throws -> SpendBreakdown {
        lock.withLock {
            breakdownCalls.append(groupBy)
            breakdownFilters.append(filter)
        }
        guard let breakdown else { throw LedgerAPIError.network("offline") }
        return breakdown
    }
    func banks() async throws -> [BankInfo] { bankRows }
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
