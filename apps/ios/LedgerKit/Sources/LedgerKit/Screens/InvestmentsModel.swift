import Foundation
import Observation

/// Wealth mode's Investments tab: every holding valued by the server (`holdings_valuation`), and
/// for one period (30 days, 90 days, YTD, 365 days) the value against cost (`holdings_value_series`)
/// and the returns (`holding_returns`) over the same days, and Add, Edit and Close for owners. A holding's own
/// screen is a `HoldingDetailModel`. Every figure is the server's; the model only loads and words them.
@MainActor
@Observable
public final class InvestmentsModel {
    public struct Content: Sendable {
        public let valuation: HoldingsValuation
        /// The synced broker accounts (`broker_accounts_summary`); empty when there are none or the
        /// read failed, and then every holding is listed on its own.
        public let brokerAccounts: [BrokerAccountSummary]

        public init(valuation: HoldingsValuation, brokerAccounts: [BrokerAccountSummary] = []) {
            self.valuation = valuation
            self.brokerAccounts = brokerAccounts
        }

        /// The broker accounts' rows, then the holdings they don't show.
        public var layout: InvestmentsLayout { InvestmentsLayout(valuation: valuation, brokerAccounts: brokerAccounts) }
    }

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    public private(set) var state: LoadState<Content> = .idle
    /// The period the value chart and the returns both show.
    public private(set) var period: ReturnsPeriod = .ninetyDays
    /// Each period's value against cost, oldest first, loaded when first shown (and again after a write).
    public private(set) var series: [ReturnsPeriod: LoadState<[HoldingValuePoint]>] = [:]
    /// Each period's returns, loaded when first shown (and again after a write).
    public private(set) var returns: [ReturnsPeriod: LoadState<HoldingReturns>] = [:]
    public private(set) var isSaving = false
    /// The last write's outcome, shown above the holdings.
    public var notice: Notice?
    /// Runs after a successful write, with the ledger: Wealth's Overview reloads.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
    }

    /// The chart's first and last day for a period (the returns' own span).
    public func range(_ period: ReturnsPeriod) -> (from: CalendarDay, to: CalendarDay) {
        let to = today()
        return period.range(today: to) ?? (to.adding(days: -365), to)
    }

    /// A new holding's form.
    public func newDraft(kind: HoldingKind = .metal) -> HoldingDraft { HoldingDraft(today: today(), kind: kind) }
    public func draft(for holding: Holding) -> HoldingDraft { HoldingDraft(holding: holding, today: today()) }

    /// A holding's own screen: its flows, values and returns. Its writes refresh this tab too.
    public func detailModel(for holdingCode: String) -> HoldingDetailModel {
        HoldingDetailModel(holdingCode: holdingCode, api: api, today: today) { [weak self] code in
            await self?.afterWrite(profileCode: code)
        }
    }

    /// The holding as the tab last loaded it (the detail screen's summary).
    public func holding(_ code: String) -> Holding? { state.value?.valuation.holding(code) }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        // Other periods re-read when next shown; the one on screen keeps its figures while it reloads.
        returns = sameKey ? returns.filter { $0.key == period } : [:]
        series = sameKey ? series.filter { $0.key == period } : [:]
        let api = self.api
        do {
            async let valuation = api.holdingsValuation(profileCode: profileCode)
            // A failed read lists every holding on its own rather than hiding any.
            async let brokers = (try? await api.brokerAccounts(profileCode: profileCode)) ?? []
            let (v, b) = try await (valuation, brokers)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            state = .loaded(Content(valuation: v, brokerAccounts: b))
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
        guard gate.isCurrent(ticket), state.value != nil else { return }
        async let s: Void = loadSeries(period, profileCode: profileCode)
        async let r: Void = loadReturns(period, profileCode: profileCode)
        _ = await (s, r)
    }

    /// Loads unless this ledger is already on screen or loading.
    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Reloads what is on screen (foreground, after a write), if anything is.
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
        period = .ninetyDays
        series = [:]
        returns = [:]
        notice = nil
        isSaving = false
    }

    // MARK: Period

    /// Shows `period`'s chart and returns, loading each the first time (or after it failed).
    public func select(_ period: ReturnsPeriod, profileCode: String) async {
        self.period = period
        let needsSeries = series[period].map { $0.value == nil && !$0.isLoading } ?? true
        let needsReturns = returns[period].map { $0.value == nil && !$0.isLoading } ?? true
        async let s: Void = needsSeries ? loadSeries(period, profileCode: profileCode) : ()
        async let r: Void = needsReturns ? loadReturns(period, profileCode: profileCode) : ()
        _ = await (s, r)
    }

    /// The value chart's state for the period on screen.
    public var selectedSeries: LoadState<[HoldingValuePoint]> { series[period] ?? .loading(previous: nil) }

    /// The returns card's state for the period on screen.
    public var selectedReturns: LoadState<HoldingReturns> { returns[period] ?? .loading(previous: nil) }

    private func loadSeries(_ period: ReturnsPeriod, profileCode: String) async {
        let (from, to) = range(period)
        series[period] = .loading(previous: series[period]?.value)
        do {
            let points = try await api.holdingsValueSeries(profileCode: profileCode, from: from, to: to)
            guard gate.requested == profileCode else { return }
            series[period] = .loaded(points.sorted { $0.date < $1.date })
        } catch {
            series[period] = .failed(LoadState<[HoldingValuePoint]>.message(for: error), previous: series[period]?.value)
        }
    }

    private func loadReturns(_ period: ReturnsPeriod, profileCode: String) async {
        returns[period] = .loading(previous: returns[period]?.value)
        do {
            let r = try await api.holdingReturns(profileCode: profileCode, period: period)
            guard gate.requested == profileCode else { return }
            returns[period] = .loaded(r)
        } catch {
            returns[period] = .failed(LoadState<HoldingReturns>.message(for: error), previous: returns[period]?.value)
        }
    }

    // MARK: Writes (owners)

    /// Validates and saves the holding. Nil when saved (the sheet closes), else the sentence the form shows.
    public func save(_ draft: HoldingDraft, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        if let problem = draft.validate(today: today()) { return problem }
        guard let submission = draft.submission(today: today()) else { return nil }
        return await write(profileCode: profileCode, saved: draft.savedMessage) {
            _ = try await $0.saveHolding(profileCode: profileCode, holding: submission)
        }
    }

    /// Closes the holding (it stops counting; the row is kept). Nil when closed, else why not.
    public func close(_ holding: Holding, profileCode: String, canEdit: Bool) async -> String? {
        guard canEdit else { return HoldingDraft.ownerOnlyMessage }
        return await write(profileCode: profileCode, saved: "\(holding.name) closed.") {
            try await $0.closeHolding(profileCode: profileCode, holdingCode: holding.holdingCode)
        }
    }

    /// The Close confirmation's wording.
    public static func closeTitle(_ holding: Holding) -> String { "Close \(holding.name)?" }
    public static let closeMessage =
        "It stops counting towards your investments and net worth. Close it when you've sold it or given it away."

    private func write(profileCode: String, saved: String,
                       _ call: (any LedgerAPI) async throws -> Void) async -> String? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            try await call(api)
        } catch {
            return HoldingDraft.message(for: error)
        }
        notice = Notice(text: saved, isError: false)
        await afterWrite(profileCode: profileCode)
        return nil
    }

    /// A holding, its flows or its value changed (here or on its screen): reload, and tell the
    /// screens that show it (net worth, cash flow, Activity).
    func afterWrite(profileCode: String) async {
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
    }
}
