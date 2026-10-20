import Foundation

/// The capture path alone (SMS and card payments) — what the outbox and the
/// App Intents need. Kept narrow so the intents' code path can be driven by a
/// stub in `swift test`.
public protocol SMSIngestAPI: Sendable {
    /// `rpc('ingest_sms')`. Idempotent per `client_msg_id`.
    func ingestSMS(profileCode: String, messages: [SMSPayload]) async throws -> [SMSIngestResult]
    /// `rpc('ingest_wallet_transactions')`: owners only, at most 200 items.
    /// Idempotent per `client_msg_id`; answers `ingest_sms`'s result shape.
    func ingestWalletPayments(profileCode: String, items: [WalletPayment]) async throws -> [SMSIngestResult]
}

/// Everything the app reads and writes. Every money figure comes from the
/// server; screens render it and never re-derive it.
public protocol LedgerAPI: SMSIngestAPI, AnalysisAPI {
    // Identity
    func profiles() async throws -> [LedgerProfile]
    func memberships() async throws -> [ProfileMembership]
    func createProfile(key: String, name: String) async throws -> String
    /// `rpc('list_profile_members')`, counted: members with access and pending
    /// invites apart. Only the `pending` flag crosses the wire (Overview's
    /// empty-ledger checklist).
    func memberCount(profileCode: String) async throws -> MemberCount

    // Analytics (SQL RPCs)
    func overview(profileCode: String, month: CalendarDay?) async throws -> Overview
    func categoryBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CategorySpend]
    /// `rpc('spend_series')` over the spend `filter` keeps (empty: all spend). With `top`, groups
    /// beyond the `top` largest fold into one "Other" row per bucket (`group_key` null), on the server.
    func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain, group: SpendGroup,
                     top: Int?, filter: SpendFilter) async throws -> [SpendPoint]
    func merchantLeaderboard(profileCode: String, from: CalendarDay, to: CalendarDay, limit: Int) async throws -> [MerchantSpend]
    func statementCycles(profileCode: String, limit: Int) async throws -> [StatementCycle]
    /// `rpc('budget_status')`: the budgets that count for the month, and with
    /// `includeInactive` every other budget of the ledger after them (`isEffective` false).
    func budgetStatus(profileCode: String, month: CalendarDay?, includeInactive: Bool) async throws -> [BudgetStatus]
    func recurringList(profileCode: String) async throws -> [RecurringCharge]
    func filterMeta(profileCode: String) async throws -> FilterMeta
    /// `rpc('activity_summary')`: count, net AED and date span of the rows Activity lists for `query`.
    func activitySummary(profileCode: String, query: ActivityQuery) async throws -> ActivitySummary
    /// `rpc('activity_day_totals')`: each of `days`' totals over every row matching `query`
    /// (days with none are left out). `p_filter` is `query.activityFilter`, as the web sends it.
    func activityDayTotals(profileCode: String, query: ActivityQuery, days: [CalendarDay]) async throws -> [DayTotal]

    // Tables / views
    /// One page of `v_transactions`, newest first, with the exact total.
    func transactions(profileCode: String, query: ActivityQuery, page: PageRequest) async throws -> TransactionPage
    /// The given rows of `v_transactions` (any order): re-reads rows after an edit.
    func transactions(profileCode: String, codes: [String]) async throws -> [LedgerTransaction]
    /// Open, unexpired `public.insights`, newest first, at most `InsightFeed.limit`.
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
    /// `rpc('set_transaction_category')`. A nil category clears the manual
    /// choice (the transaction's, and with `applyToMerchant` the merchant's).
    func setTransactionCategory(txnCode: String, categoryCode: String?, applyToMerchant: Bool) async throws
    /// Updates one user field of `public.transactions` (`notes` or
    /// `exclude_from_spend`, the columns `authenticated` may update). Owners only (RLS).
    func updateTransaction(txnCode: String, edit: TransactionEdit) async throws
    func uploadStatements(profileCode: String, files: [UploadFile]) async throws -> UploadResponse

    // Transaction detail (SupabaseLedgerAPI+Transactions.swift): what the sheet shows beside the row
    /// `rpc('merchant_context')`: visits, average and 6-month spend at the merchant.
    func merchantContext(profileCode: String, merchantCode: String) async throws -> MerchantContext
    /// `public.transaction_evidence` of the transaction with its statement line or SMS (no SMS body).
    func transactionEvidence(profileCode: String, txnCode: String) async throws -> [EvidenceItem]
    /// One SMS's text, read only when the reader opens it on the sheet. Never logged or kept.
    func smsBody(profileCode: String, smsCode: String) async throws -> String?
    /// The reversal pair of `txn`, in either direction (the row itself left out).
    func relatedTransactions(profileCode: String, txn: LedgerTransaction) async throws -> [LedgerTransaction]

    // Statement detail, spend split, banks, upload timeline (SupabaseLedgerAPI+Statements.swift)
    /// `rpc('statement_detail')`. P0002 when the statement is unknown to the profile.
    func statementDetail(profileCode: String, stmtCode: String) async throws -> StatementDetail
    /// `rpc('spend_breakdown')`: top `topN` groups plus Others, by month, of the spend `filter` keeps.
    func spendBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay, groupBy: SpendSplitGrouping,
                        topN: Int, filter: SpendFilter) async throws -> SpendBreakdown
    /// `public.banks` (names, logos, SMS senders).
    func banks() async throws -> [BankInfo]
    /// `public.document_events` of these documents, in server order.
    func documentEvents(profileCode: String, docCodes: [String]) async throws -> [DocumentEvent]
    /// New `document_events` rows of the profile, live (Realtime INSERTs).
    func documentEventStream(profileCode: String) -> AsyncStream<DocumentEvent>

    // Activity bulk actions (SupabaseLedgerAPI+Activity.swift, PAR-11)
    /// `rpc('activity_selection_summary')`: count, net AED and excluded count of a selection (members).
    func activitySelectionSummary(profileCode: String, selection: ActivityBulkSelection) async throws -> ActivitySelectionSummary
    /// `rpc('bulk_update_transactions')`: writes `patch` to every selected row (owners; 42501
    /// otherwise). Returns how many rows changed.
    func bulkUpdateTransactions(profileCode: String, patch: ActivityBulkPatch, selection: ActivityBulkSelection) async throws -> Int

    // Statement PDF (SupabaseLedgerAPI+StatementPDF.swift, PAR-13)
    /// A short-lived signed URL for the document's PDF in the `statements` bucket (members).
    /// `StatementPDF.Failure.notAvailable` when the document has no stored file.
    func statementPDFURL(profileCode: String, docCode: String) async throws -> URL

    // Budgets (SupabaseLedgerAPI+Budgets.swift)
    /// Inserts a new budget (no `budgetCode`) or updates one. Owners only (RLS).
    func saveBudget(profileCode: String, draft: BudgetDraft) async throws
    func deleteBudget(budgetCode: String) async throws
    /// `public.accounts` of the profile (active and closed), by bank: the budget form's cards.
    func accounts(profileCode: String) async throws -> [LedgerAccount]

    // Unusual spending and SMS format proposals (SupabaseLedgerAPI+Insights.swift, PAR-9 / PAR-14)
    /// `rpc('anomalies')`: unusual charges in the range, largest first; members read.
    func anomalies(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [Anomaly]
    /// `rpc('dismiss_anomaly')`, "This is fine": owners only. P0002 for a transaction not in the ledger.
    func dismissAnomaly(profileCode: String, txnCode: String) async throws
    /// `rpc('set_sms_template_active')`: accepts (true) or rejects (false) an AI-proposed SMS
    /// format, closing the reviews waiting on it. Owners of a ledger with such a review only (42501).
    func setSMSTemplateActive(templateCode: String, active: Bool) async throws

    // Cards (SupabaseLedgerAPI+Wallet.swift)
    /// `public.cards` of the profile, by bank and last 4.
    func cards(profileCode: String) async throws -> [LedgerCard]
    /// Sets (or clears, with nil) `cards.wallet_name`. Owners only; 23505 when
    /// another card of the ledger already has the name (case-insensitive).
    func updateCardWalletName(cardCode: String, name: String?) async throws

    // Cash: bank accounts, balances and cash flow (SupabaseLedgerAPI+Cash.swift, Phase 2d)
    /// `rpc('cash_position')`: every active bank account's balance and the AED total (members).
    func cashPosition(profileCode: String) async throws -> CashPosition
    /// `rpc('cash_flow')`: each month's total per flow plus its `net` row, between the dates, for
    /// the whole ledger or one account (members). Rows say whether their month `is_partial`.
    func cashFlow(profileCode: String, from: CalendarDay, to: CalendarDay, accountCode: String?) async throws -> [CashFlowRow]
    /// `rpc('record_balance')`: the account's balance as of now, as a decimal string (owners; 42501
    /// otherwise, 22023 for a malformed amount, P0002 for an account not in the ledger).
    func recordBalance(profileCode: String, accountCode: String, balance: String) async throws
    /// `rpc('create_bank_account')`: returns the new `account_code` (owners; 23505 when the bank
    /// and ref exist, 22023 for a bad kind or ref, P0002 for an unknown bank).
    func createBankAccount(profileCode: String, bankCode: String, kind: BankAccountKind, accountRef: String,
                           nickname: String?) async throws -> String

    // Wealth mode (SupabaseLedgerAPI+Wealth.swift)
    /// `rpc('account_ledger')`: a bank account's rows for the period with flow and running balance,
    /// plus opening/closing balance and money in/out (members; at most 400 days; P0002 for a card).
    func accountLedger(profileCode: String, accountCode: String, from: CalendarDay, to: CalendarDay) async throws -> AccountLedger
    /// `rpc('bank_balance_series')`: a bank account's end-of-day balances (members; at most 400 days).
    func bankBalanceSeries(profileCode: String, accountCode: String, from: CalendarDay, to: CalendarDay) async throws -> [BalancePoint]
    /// `rpc('net_worth')`: bank cash − what the cards owe, with completeness and each card (members).
    func netWorth(profileCode: String) async throws -> NetWorth
    /// `rpc('net_worth_series')`: each month's last nightly snapshot, then today's live figure (members).
    func netWorthSeries(profileCode: String, months: Int) async throws -> [NetWorthPoint]

    /// Fires whenever a row the screens show changes (transactions, SMS,
    /// documents, insights) for the profile. Ends when the caller stops iterating.
    func changes(profileCode: String) -> AsyncStream<LedgerChange>
}

extension LedgerAPI {
    /// The whole ledger's cash flow.
    public func cashFlow(profileCode: String, from: CalendarDay, to: CalendarDay) async throws -> [CashFlowRow] {
        try await cashFlow(profileCode: profileCode, from: from, to: to, accountCode: nil)
    }

    /// The budgets that count for the month only (Insights' budgets card).
    public func budgetStatus(profileCode: String, month: CalendarDay?) async throws -> [BudgetStatus] {
        try await budgetStatus(profileCode: profileCode, month: month, includeInactive: false)
    }

    /// All spend, unfiltered.
    public func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain,
                            group: SpendGroup) async throws -> [SpendPoint] {
        try await spendSeries(profileCode: profileCode, from: from, to: to, grain: grain, group: group, filter: SpendFilter())
    }

    /// Every group, none folded.
    public func spendSeries(profileCode: String, from: CalendarDay, to: CalendarDay, grain: SpendGrain,
                            group: SpendGroup, filter: SpendFilter) async throws -> [SpendPoint] {
        try await spendSeries(profileCode: profileCode, from: from, to: to, grain: grain, group: group, top: nil,
                              filter: filter)
    }

    /// All spend, unfiltered.
    public func spendBreakdown(profileCode: String, from: CalendarDay, to: CalendarDay, groupBy: SpendSplitGrouping,
                               topN: Int) async throws -> SpendBreakdown {
        try await spendBreakdown(profileCode: profileCode, from: from, to: to, groupBy: groupBy, topN: topN,
                                 filter: SpendFilter())
    }

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

    /// The request never reached Ledger because the phone has no usable
    /// connection (no data, airplane mode, roaming off, DNS or connect
    /// failure, timeout). Says nothing about the message, so the outbox does
    /// not count it as an attempt.
    public var isUnreachable: Bool {
        guard case let .network(code) = self, let raw = Int(code) else { return false }
        return Self.unreachableURLErrorCodes.contains(URLError.Code(rawValue: raw))
    }

    static let unreachableURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
    ]

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
