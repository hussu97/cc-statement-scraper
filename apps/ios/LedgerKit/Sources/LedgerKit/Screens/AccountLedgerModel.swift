import Foundation
import Observation

/// One bank account's ledger (Wealth mode): a month of its rows with flow and running balance
/// (`account_ledger`), the month's opening, in, out and closing, and the last 90 days of
/// end-of-day balances for the chart (`bank_balance_series`). A row opens the transaction sheet,
/// where an owner files a transfer under Support, Saving or a category; the ledger re-reads after.
@MainActor
@Observable
public final class AccountLedgerModel: TransactionEditing {
    public let accountCode: String
    /// The month on screen, back to two years (`MonthRange.fallbackMonths`).
    public let month: MonthSelection
    public private(set) var state: LoadState<AccountLedger> = .idle
    public private(set) var series: LoadState<[BalancePoint]> = .idle
    /// A failed write or a transaction that couldn't be opened.
    public var errorMessage: String?
    /// Runs after a write, with the ledger: Wealth's Overview and Accounts reload.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private let categoryOptions: @MainActor () -> [FilterMeta.CategoryOption]
    private var gate = RequestGate<Key>()
    private var seriesGate = RequestGate<String>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let month: CalendarDay
    }

    public init(api: any LedgerAPI, accountCode: String,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                categories: @escaping @MainActor () -> [FilterMeta.CategoryOption] = { [] }) {
        self.api = api
        self.accountCode = accountCode
        self.today = today
        categoryOptions = categories
        month = MonthSelection(today: today)
    }

    /// What the transaction sheet offers (Activity's `filter_meta`, archived ones left out).
    public var categories: [FilterMeta.CategoryOption] { categoryOptions() }

    public var emptyMessage: String { AccountLedger.emptyMessage(month.month, today: today()) }

    /// The ledger's sections, by day.
    public var sections: [AccountLedgerDay] { state.value?.sections(today: today()) ?? [] }

    /// Loads the month on screen (and the balance chart, once per ledger).
    public func load(profileCode: String) async {
        let first = month.month
        let key = Key(profileCode: profileCode, month: first)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        async let chart: Void = loadSeries(profileCode: profileCode, force: sameKey)
        do {
            let ledger = try await api.accountLedger(profileCode: profileCode, accountCode: accountCode,
                                                     from: first, to: first.endOfMonth)
            guard gate.isCurrent(ticket) else { return await chart }
            gate.finish(key)
            state = .loaded(ledger)
        } catch {
            if gate.isCurrent(ticket) { state = state.fail(error) }
        }
        await chart
    }

    /// Loads unless this month of this ledger is on screen or loading.
    public func loadIfNeeded(profileCode: String) async {
        let key = Key(profileCode: profileCode, month: month.month)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// The last `BalanceSeries.days` days up to today; `force` re-reads one already loaded.
    private func loadSeries(profileCode: String, force: Bool) async {
        guard force || seriesGate.requested != profileCode else { return }
        let (ticket, sameKey) = seriesGate.begin(profileCode)
        series = sameKey ? series.startLoading() : .loading(previous: nil)
        let end = today()
        do {
            let points = try await api.bankBalanceSeries(profileCode: profileCode, accountCode: accountCode,
                                                         from: end.adding(days: -(BalanceSeries.days - 1)), to: end)
            guard seriesGate.isCurrent(ticket) else { return }
            seriesGate.finish(profileCode)
            series = .loaded(points)
        } catch {
            if seriesGate.isCurrent(ticket) { series = series.fail(error) }
        }
    }

    // MARK: The transaction sheet

    /// The row's full transaction, for the sheet; nil (with `errorMessage`) when it is gone.
    public func transaction(_ txnCode: String, profileCode: String) async -> LedgerTransaction? {
        do {
            if let txn = try await api.transactions(profileCode: profileCode, codes: [txnCode]).first { return txn }
            errorMessage = "This transaction is no longer in this ledger."
        } catch {
            errorMessage = LoadState<Int>.message(for: error)
        }
        return nil
    }

    public func detail(for txn: LedgerTransaction, profileCode: String) -> TransactionDetailModel {
        TransactionDetailModel(transaction: txn, profileCode: profileCode, api: api)
    }

    public func saveCategory(_ txn: LedgerTransaction, to categoryCode: String?, applyToMerchant: Bool,
                             profileCode: String) async throws {
        try await api.setTransactionCategory(txnCode: txn.txnCode, categoryCode: categoryCode,
                                             applyToMerchant: applyToMerchant && txn.merchantCode != nil)
        await written(profileCode: profileCode)
    }

    public func saveEdit(_ txn: LedgerTransaction, _ edit: TransactionEdit, profileCode: String) async throws {
        try await api.updateTransaction(txnCode: txn.txnCode, edit: edit)
        await written(profileCode: profileCode)
    }

    /// Links or unlinks the payment; the month re-reads (its flow becomes or stops being saving).
    public func saveLink(_ txn: LedgerTransaction, holdingCode: String?, profileCode: String) async throws {
        try await api.linkTransaction(profileCode: profileCode, txnCode: txn.txnCode, holdingCode: holdingCode)
        await written(profileCode: profileCode)
    }

    /// A category (and so a flow) or balance changed: the month and the chart re-read.
    private func written(profileCode: String) async {
        await load(profileCode: profileCode)
        await onChange?(profileCode)
    }

    /// Realtime and the foreground, once opened for this ledger.
    public func refresh(profileCode: String) async {
        guard gate.requested?.profileCode == profileCode else { return }
        await load(profileCode: profileCode)
    }
}

/// Makes and keeps each account's ledger model, so going back to an account shows it at once
/// and Realtime refreshes the ones opened. Cleared when the ledger switches.
@MainActor
@Observable
public final class AccountLedgers {
    @ObservationIgnored private let api: any LedgerAPI
    @ObservationIgnored private let today: @Sendable () -> CalendarDay
    @ObservationIgnored private let categories: @MainActor () -> [FilterMeta.CategoryOption]
    @ObservationIgnored private var models: [String: AccountLedgerModel] = [:]
    /// Set on each model it makes.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                categories: @escaping @MainActor () -> [FilterMeta.CategoryOption] = { [] }) {
        self.api = api
        self.today = today
        self.categories = categories
    }

    public func model(for accountCode: String) -> AccountLedgerModel {
        if let model = models[accountCode] { return model }
        let model = AccountLedgerModel(api: api, accountCode: accountCode, today: today, categories: categories)
        model.onChange = { [weak self] code in await self?.onChange?(code) }
        models[accountCode] = model
        return model
    }

    /// Every opened ledger re-reads (Realtime, the foreground).
    public func refresh(profileCode: String) async {
        for model in models.values { await model.refresh(profileCode: profileCode) }
    }

    public func reset() { models = [:] }
}
