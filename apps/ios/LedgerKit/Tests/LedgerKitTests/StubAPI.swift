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
                           accounts: inbox.accounts, total: inbox.reviews.count, formats: inbox.formats)
    }
    func resolveReview(reviewCode: String, action: ReviewAction) async throws -> String {
        lock.withLock { resolved.append((reviewCode, action)) }
        if let resolveError { throw resolveError }
        return action.outcomeWithoutResolve ?? "dismissed"
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
    var memberCountValue: MemberCount? = MemberCount(members: 1)
    func memberCount(profileCode: String) async throws -> MemberCount {
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
    private(set) var recategorised: [(txn: String, category: String?, merchant: Bool)] = []
    /// `updateTransaction` writes; `transactionWriteError` is thrown by both transaction writes when set.
    private(set) var transactionEdits: [(txn: String, edit: TransactionEdit)] = []
    var transactionWriteError: LedgerAPIError?
    /// `filter_meta.date_range.min`.
    var firstTransactionDay: CalendarDay?
    /// Months `overview` was asked for (nil: current).
    private(set) var overviewMonths: [CalendarDay?] = []
    var overviewFixture: Overview?
    /// Thrown by `overview` when set.
    var overviewError: LedgerAPIError?

    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview {
        lock.withLock { overviewMonths.append(month) }
        count("overview")
        if let overviewError { throw overviewError }
        guard let overviewFixture else { throw LedgerAPIError.noProfile }
        return overviewFixture
    }
    /// `category_breakdown` rows.
    var categoryRows: [CategorySpend] = []
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend] {
        count("categoryBreakdown")
        return categoryRows
    }
    /// `spend_series` answers (all spend when unset), and the filters it was asked for.
    var seriesPoints: [SpendPoint] = []
    /// Answers by `p_group`, over `seriesPoints` (Trends asks for the totals and a grouping at once).
    var seriesByGroup: [SpendGroup: [SpendPoint]] = [:]
    var seriesError: LedgerAPIError?
    private(set) var seriesFilters: [SpendFilter] = []
    /// Each `spend_series` call: grain, group, `p_top` and range.
    private(set) var seriesRequests: [(grain: SpendGrain, group: SpendGroup, top: Int?, from: CalendarDay, to: CalendarDay)] = []
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup,
                     top: Int?, filter: SpendFilter) async throws -> [SpendPoint] {
        lock.withLock {
            seriesFilters.append(filter)
            seriesRequests.append((grain, group, top, from, to))
        }
        if let seriesError { throw seriesError }
        return seriesByGroup[group] ?? seriesPoints
    }
    /// `p_limit` of each `merchant_leaderboard` call.
    private(set) var merchantLimits: [Int] = []
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend] {
        lock.withLock { merchantLimits.append(limit) }
        return []
    }
    /// `statement_cycles` rows, newest first (sliced to `p_limit`), and each call's limit.
    var cycleRows: [StatementCycle] = []
    private(set) var cycleLimits: [Int] = []
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle] {
        count("statementCycles")
        lock.withLock { cycleLimits.append(limit) }
        return Array(cycleRows.prefix(limit))
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
    // MARK: Cash (Phase 2d): scripted answers and each write
    /// `cash_position`'s answer; nil throws (a server before Phase 2d, offline).
    var cashPositionFixture: CashPosition?
    var cashFlowRows: [CashFlowRow] = []
    var cashFlowError: LedgerAPIError?
    private(set) var cashFlowRanges: [(from: CalendarDay, to: CalendarDay)] = []
    private(set) var cashFlowAccounts: [String?] = []
    /// Thrown by `recordBalance` / `createBankAccount` when set.
    var cashWriteError: LedgerAPIError?
    private(set) var recordedBalances: [(profile: String, account: String, balance: String)] = []
    private(set) var createdBankAccounts: [(bank: String, kind: BankAccountKind, ref: String, nickname: String?)] = []
    func cashPosition(profileCode: String) async throws -> CashPosition {
        count("cashPosition")
        guard let cashPositionFixture = lock.withLock({ cashPositionFixture }) else { throw LedgerAPIError.network("-1009") }
        return cashPositionFixture
    }
    func cashFlow(profileCode: String, from: CalendarDay, to: CalendarDay, accountCode: String?) async throws -> [CashFlowRow] {
        count("cashFlow")
        lock.withLock {
            cashFlowRanges.append((from, to))
            cashFlowAccounts.append(accountCode)
        }
        if let cashFlowError { throw cashFlowError }
        return cashFlowRows
    }
    func recordBalance(profileCode: String, accountCode: String, balance: String) async throws {
        if let cashWriteError { throw cashWriteError }
        lock.withLock { recordedBalances.append((profileCode, accountCode, balance)) }
    }
    func createBankAccount(profileCode: String, bankCode: String, kind: BankAccountKind, accountRef: String,
                           nickname: String?) async throws -> String {
        if let cashWriteError { throw cashWriteError }
        lock.withLock { createdBankAccounts.append((bankCode, kind, accountRef, nickname)) }
        return "acc_new"
    }
    // MARK: Wealth mode: scripted answers, and each call's arguments
    var accountLedgerFixture: AccountLedger?
    var balanceSeriesFixture: [BalancePoint] = []
    var netWorthFixture: NetWorth?
    var netWorthSeriesFixture: [NetWorthPoint] = []
    var netWorthSeriesError: LedgerAPIError?
    private(set) var ledgerRanges: [(account: String, from: CalendarDay, to: CalendarDay)] = []
    private(set) var balanceSeriesRanges: [(account: String, from: CalendarDay, to: CalendarDay)] = []
    func accountLedger(profileCode: String, accountCode: String, from: CalendarDay, to: CalendarDay) async throws -> AccountLedger {
        count("accountLedger")
        lock.withLock { ledgerRanges.append((accountCode, from, to)) }
        guard let fixture = lock.withLock({ accountLedgerFixture }) else {
            throw LedgerAPIError.server(status: nil, code: "P0002", message: "bank account not found")
        }
        return fixture
    }
    func bankBalanceSeries(profileCode: String, accountCode: String, from: CalendarDay, to: CalendarDay) async throws -> [BalancePoint] {
        count("bankBalanceSeries")
        lock.withLock { balanceSeriesRanges.append((accountCode, from, to)) }
        return balanceSeriesFixture
    }
    func netWorth(profileCode: String) async throws -> NetWorth {
        count("netWorth")
        guard let fixture = lock.withLock({ netWorthFixture }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func netWorthSeries(profileCode: String, months: Int) async throws -> [NetWorthPoint] {
        count("netWorthSeries")
        if let netWorthSeriesError { throw netWorthSeriesError }
        return netWorthSeriesFixture
    }
    // MARK: Investments: scripted answers, and each call's arguments
    /// `holdings_valuation`'s answer; nil throws (offline).
    var valuationFixture: HoldingsValuation?
    var valueSeriesFixture: [HoldingValuePoint] = []
    var valueSeriesError: LedgerAPIError?
    var priceSeriesFixture: [MetalPricePoint] = []
    /// Thrown by `saveHolding` / `closeHolding` when set.
    var holdingWriteError: LedgerAPIError?
    private(set) var valueSeriesRanges: [(from: CalendarDay, to: CalendarDay)] = []
    private(set) var priceSeriesCalls: [(quote: MetalQuote, from: CalendarDay, to: CalendarDay)] = []
    private(set) var savedHoldings: [HoldingSubmission] = []
    private(set) var closedHoldings: [String] = []
    func holdingsValuation(profileCode: String) async throws -> HoldingsValuation {
        count("holdingsValuation")
        guard let fixture = lock.withLock({ valuationFixture }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func holdingsValueSeries(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [HoldingValuePoint] {
        count("holdingsValueSeries")
        lock.withLock { valueSeriesRanges.append((from, to)) }
        if let valueSeriesError { throw valueSeriesError }
        return valueSeriesFixture
    }
    func metalPriceSeries(quote: MetalQuote, from: CalendarDay, to: CalendarDay) async throws -> [MetalPricePoint] {
        count("metalPriceSeries")
        lock.withLock { priceSeriesCalls.append((quote, from, to)) }
        return priceSeriesFixture
    }
    func saveHolding(profileCode: String, holding: HoldingSubmission) async throws -> String {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { savedHoldings.append(holding) }
        return holding.holdingCode ?? "hld_new"
    }
    func closeHolding(profileCode: String, holdingCode: String) async throws {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { closedHoldings.append(holdingCode) }
    }
    /// `holding_detail`'s answer; nil throws (offline).
    var holdingDetailFixture: HoldingDetail?
    /// Each period's `holding_returns`; a missing period throws (offline).
    var returnsFixtures: [ReturnsPeriod: HoldingReturns] = [:]
    var savingsFixture: [SavingByHolding] = []
    var savingsError: LedgerAPIError?
    private(set) var returnsCalls: [ReturnsPeriod] = []
    private(set) var recordedValues: [ValueSubmission] = []
    private(set) var addedFlows: [FlowSubmission] = []
    private(set) var removedFlows: [String] = []
    private(set) var links: [(txn: String, holding: String?)] = []
    private(set) var savingsRanges: [(from: CalendarDay, to: CalendarDay, account: String?)] = []
    func holdingDetail(profileCode: String, holdingCode: String) async throws -> HoldingDetail {
        count("holdingDetail")
        guard let fixture = lock.withLock({ holdingDetailFixture }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func holdingReturns(profileCode: String, period: ReturnsPeriod) async throws -> HoldingReturns {
        lock.withLock { returnsCalls.append(period) }
        guard let fixture = lock.withLock({ returnsFixtures[period] }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func recordHoldingValue(profileCode: String, value: ValueSubmission) async throws {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { recordedValues.append(value) }
    }
    func addHoldingFlow(profileCode: String, flow: FlowSubmission) async throws {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { addedFlows.append(flow) }
    }
    func removeHoldingFlow(profileCode: String, flowCode: String) async throws {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { removedFlows.append(flowCode) }
    }
    func linkTransaction(profileCode: String, txnCode: String, holdingCode: String?) async throws {
        if let holdingWriteError { throw holdingWriteError }
        lock.withLock { links.append((txnCode, holdingCode)) }
    }
    func cashFlowSavings(profileCode: String, from: CalendarDay, to: CalendarDay,
                         accountCode: String?) async throws -> [SavingByHolding] {
        count("cashFlowSavings")
        lock.withLock { savingsRanges.append((from, to, accountCode)) }
        if let savingsError { throw savingsError }
        return savingsFixture
    }
    // MARK: Structured notes: scripted answers, and each write
    /// `structured_notes_summary`'s answer; nil throws (offline).
    var notesFixture: [NoteSummary]?
    /// `structured_note_detail`'s answer; nil throws (offline).
    var noteDetailFixture: NoteDetail?
    /// `termsheet-extract`'s answer, or the error it throws; nil throws offline.
    var extractResult: Result<TermSheetExtract, LedgerAPIError>?
    /// `stock-prices`' answer, or the error it throws; nil answers nothing stored.
    var pricesResult: Result<NotePriceRefresh, LedgerAPIError>?
    /// Thrown by the notes' writes (create, cancel, entries) when set.
    var noteWriteError: LedgerAPIError?
    private(set) var createdNotes: [(form: NoteDraftForm, draft: NoteDraft)] = []
    private(set) var cancelledNotes: [String] = []
    private(set) var extractedFiles: [String] = []
    private(set) var accountEntries: [AccountEntryDraft.Submission] = []
    func structuredNotes(profileCode: String) async throws -> [NoteSummary] {
        count("structuredNotes")
        guard let fixture = lock.withLock({ notesFixture }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func structuredNoteDetail(profileCode: String, holdingCode: String) async throws -> NoteDetail {
        count("structuredNoteDetail")
        guard let fixture = lock.withLock({ noteDetailFixture }) else { throw LedgerAPIError.network("-1009") }
        return fixture
    }
    func cancelStructuredNote(profileCode: String, holdingCode: String) async throws {
        if let noteWriteError { throw noteWriteError }
        lock.withLock { cancelledNotes.append(holdingCode) }
    }
    func createStructuredNote(profileCode: String, draft: NoteDraftForm, reviewed: NoteDraft) async throws -> String {
        if let noteWriteError { throw noteWriteError }
        lock.withLock { createdNotes.append((draft, reviewed)) }
        return "hld_note"
    }
    func refreshNotePrices(profileCode: String) async throws -> NotePriceRefresh {
        count("refreshNotePrices")
        switch lock.withLock({ pricesResult }) {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: return NotePriceRefresh(stored: 0)
        }
    }
    func extractTermSheet(profileCode: String, file: UploadFile) async throws -> TermSheetExtract {
        lock.withLock { extractedFiles.append(file.filename) }
        switch lock.withLock({ extractResult }) {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: throw LedgerAPIError.network("-1009")
        }
    }
    func addAccountEntry(profileCode: String, entry: AccountEntryDraft.Submission) async throws -> String {
        if let noteWriteError { throw noteWriteError }
        lock.withLock { accountEntries.append(entry) }
        return "ent_new"
    }
    // MARK: Analysis (PAR-12): scripted answers, and each call's arguments
    var dailyRows: [DailySpend] = []
    var hourRows: [HourWeekdaySpend] = []
    var yoyRows: [YearOverYearMonth] = []
    var fxRows: [FxSpend] = []
    var analysisError: LedgerAPIError?
    private(set) var analysisCalls: [String] = []
    func dailySpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [DailySpend] {
        try analysisAnswer("daily_spend \(from.iso) \(to.iso)", dailyRows)
    }
    func hourWeekdayPattern(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [HourWeekdaySpend] {
        try analysisAnswer("hour_weekday_pattern \(from.iso) \(to.iso)", hourRows)
    }
    func yearOverYear(profileCode: String, year: Int) async throws -> [YearOverYearMonth] {
        try analysisAnswer("yoy_compare \(year)", yoyRows)
    }
    func fxSpend(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [FxSpend] {
        try analysisAnswer("fx_spend \(from.iso) \(to.iso)", fxRows)
    }
    private func analysisAnswer<T>(_ call: String, _ rows: T) throws -> T {
        let error = lock.withLock {
            analysisCalls.append(call)
            return analysisError
        }
        if let error { throw error }
        return rows
    }
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
    /// `activity_day_totals` answers by day (days not here aren't returned), the calls, and an error to throw.
    var dayTotalRows: [CalendarDay: DayTotal] = [:]
    var dayTotalsError: LedgerAPIError?
    private(set) var dayTotalCalls: [(query: ActivityQuery, days: [CalendarDay])] = []
    func activityDayTotals(profileCode: String, query: ActivityQuery, days: [CalendarDay]) async throws -> [DayTotal] {
        let (rows, error) = lock.withLock {
            dayTotalCalls.append((query, days))
            return (dayTotalRows, dayTotalsError)
        }
        if let error { throw error }
        return days.compactMap { rows[$0] }
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
    // MARK: Insights feed, unusual spending, SMS format proposals (PAR-9, PAR-14)

    var insightRows: [Insight] = []
    var insightsError: LedgerAPIError?
    private(set) var dismissedInsights: [String] = []
    func insights(profileCode: String) async throws -> [Insight] {
        count("insights")
        if let insightsError { throw insightsError }
        return lock.withLock { insightRows }
    }
    func dismissInsight(insightCode: String) async throws {
        lock.withLock {
            dismissedInsights.append(insightCode)
            insightRows.removeAll { $0.insightCode == insightCode }
        }
    }
    var anomalyRows: [Anomaly] = []
    var anomalyError: LedgerAPIError?
    private(set) var anomalyRequests: [(from: CalendarDay, to: CalendarDay)] = []
    private(set) var dismissedAnomalies: [String] = []
    func anomalies(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [Anomaly] {
        let (rows, error) = lock.withLock {
            anomalyRequests.append((from, to))
            return (anomalyRows, anomalyError)
        }
        if let error { throw error }
        return rows
    }
    func dismissAnomaly(profileCode: String, txnCode: String) async throws {
        if let anomalyError { throw anomalyError }
        lock.withLock {
            dismissedAnomalies.append(txnCode)
            anomalyRows.removeAll { $0.txnCode == txnCode }
        }
    }
    private(set) var formatDecisions: [(template: String, active: Bool)] = []
    func setSMSTemplateActive(templateCode: String, active: Bool) async throws {
        lock.withLock { formatDecisions.append((templateCode, active)) }
    }
    var documentRows: [DocumentRecord] = []
    func documents(profileCode: String, page: PageRequest) async throws -> ListPage<DocumentRecord> {
        count("documents")
        return ListPage(items: Array(documentRows.dropFirst(page.offset).prefix(page.limit)), total: documentRows.count)
    }
    func setTransactionCategory(txnCode: String, categoryCode: String?, applyToMerchant: Bool) async throws {
        if let transactionWriteError { throw transactionWriteError }
        lock.withLock { recategorised.append((txnCode, categoryCode, applyToMerchant)) }
    }
    func updateTransaction(txnCode: String, edit: TransactionEdit) async throws {
        if let transactionWriteError { throw transactionWriteError }
        lock.withLock { transactionEdits.append((txnCode, edit)) }
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
    // MARK: Transaction detail

    var merchantContexts: [String: MerchantContext] = [:]
    var evidenceRows: [String: [EvidenceItem]] = [:]
    var evidenceError: LedgerAPIError?
    var smsBodies: [String: String] = [:]
    private(set) var smsBodyReads: [String] = []
    func merchantContext(profileCode: String, merchantCode: String) async throws -> MerchantContext {
        count("merchantContext")
        guard let context = merchantContexts[merchantCode] else { throw LedgerAPIError.network("-1009") }
        return context
    }
    func transactionEvidence(profileCode: String, txnCode: String) async throws -> [EvidenceItem] {
        if let evidenceError { throw evidenceError }
        return EvidenceItem.sorted(evidenceRows[txnCode] ?? [])
    }
    func smsBody(profileCode: String, smsCode: String) async throws -> String? {
        lock.withLock { smsBodyReads.append(smsCode) }
        return smsBodies[smsCode]
    }
    func relatedTransactions(profileCode: String, txn: LedgerTransaction) async throws -> [LedgerTransaction] {
        let all = lock.withLock { transactionRows[profileCode] ?? [] }
        return all.filter { ($0.relatedTxnCode == txn.txnCode || $0.txnCode == txn.relatedTxnCode) && $0.txnCode != txn.txnCode }
    }

    // MARK: Statement detail, spend split, banks, upload timeline

    var detail: StatementDetail?
    var detailError: LedgerAPIError?
    var breakdown: SpendBreakdown?
    /// Per-grouping answers, ahead of `breakdown`.
    var breakdownByGroup: [SpendSplitGrouping: SpendBreakdown] = [:]
    /// Each `spend_breakdown` call's range and top N.
    private(set) var breakdownRequests: [(groupBy: SpendSplitGrouping, from: CalendarDay, to: CalendarDay, topN: Int)] = []
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
            breakdownRequests.append((groupBy, from, to, topN))
        }
        guard let answer = breakdownByGroup[groupBy] ?? breakdown else { throw LedgerAPIError.network("offline") }
        return answer
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

    // MARK: Activity bulk actions (PAR-11)

    /// `activity_selection_summary`'s answer (zero rows when unset), and each call's selection.
    var selectionSummaryResult: Result<ActivitySelectionSummary, LedgerAPIError>?
    private(set) var selectionSummaryCalls: [ActivityBulkSelection] = []
    /// `bulk_update_transactions`' answer: rows changed, or the error to throw.
    var bulkUpdateResult: Result<Int, LedgerAPIError> = .success(0)
    private(set) var bulkUpdates: [(patch: ActivityBulkPatch, selection: ActivityBulkSelection)] = []
    func activitySelectionSummary(profileCode: String, selection: ActivityBulkSelection) async throws -> ActivitySelectionSummary {
        let result = lock.withLock {
            selectionSummaryCalls.append(selection)
            return selectionSummaryResult
        }
        switch result {
        case .success(let s)?: return s
        case .failure(let e)?: throw e
        case nil: return ActivitySelectionSummary(txnCount: 0, netAed: 0)
        }
    }
    func bulkUpdateTransactions(profileCode: String, patch: ActivityBulkPatch,
                                selection: ActivityBulkSelection) async throws -> Int {
        let result = lock.withLock {
            bulkUpdates.append((patch, selection))
            return bulkUpdateResult
        }
        return try result.get()
    }

    // MARK: Statement PDF (PAR-13)

    /// `statementPDFURL`'s answer by doc code; a missing code is `.notAvailable`.
    var pdfURLs: [String: Result<URL, any Error>] = [:]
    private(set) var pdfURLRequests: [(profile: String, doc: String)] = []
    func statementPDFURL(profileCode: String, docCode: String) async throws -> URL {
        let answer = lock.withLock {
            pdfURLRequests.append((profileCode, docCode))
            return pdfURLs[docCode]
        }
        guard let answer else { throw StatementPDF.Failure.notAvailable }
        return try answer.get()
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
