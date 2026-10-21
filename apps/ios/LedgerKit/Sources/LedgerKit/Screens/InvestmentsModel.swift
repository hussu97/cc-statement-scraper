import Foundation
import Observation

/// Wealth mode's Investments tab: every holding valued by the server (`holdings_valuation`), the
/// 90-day value against cost (`holdings_value_series`) or a metal price (`metal_price_series`),
/// returns for a period (`holding_returns`), and Add, Edit and Close for owners. A holding's own
/// screen is a `HoldingDetailModel`. Every figure is the server's; the model only loads and words them.
@MainActor
@Observable
public final class InvestmentsModel {
    public struct Content: Sendable {
        public let valuation: HoldingsValuation
        /// Oldest first; empty when it failed (`seriesError`).
        public let series: [HoldingValuePoint]
        public let seriesError: String?

        public init(valuation: HoldingsValuation, series: [HoldingValuePoint] = [], seriesError: String? = nil) {
            self.valuation = valuation
            self.series = series
            self.seriesError = seriesError
        }
    }

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    public private(set) var state: LoadState<Content> = .idle
    /// The chart on screen.
    public private(set) var chart: InvestmentsChart = .value
    /// Each price chart's days, loaded when first shown.
    public private(set) var priceSeries: [MetalQuote: LoadState<[MetalPricePoint]>] = [:]
    /// The returns card's period.
    public private(set) var returnsPeriod: ReturnsPeriod = .all
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

    /// The chart's first and last day.
    public var range: (from: CalendarDay, to: CalendarDay) {
        let to = today()
        return (to.adding(days: -(InvestmentsChart.days - 1)), to)
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
        if !sameKey { priceSeries = [:] }
        // Other periods re-read when next shown; the one on screen keeps its figures while it reloads.
        returns = sameKey ? returns.filter { $0.key == returnsPeriod } : [:]
        let (from, to) = range
        let api = self.api
        do {
            async let valuation = api.holdingsValuation(profileCode: profileCode)
            async let series: Result<[HoldingValuePoint], any Error> = {
                do {
                    return .success(try await api.holdingsValueSeries(profileCode: profileCode, from: from, to: to))
                } catch {
                    return .failure(error)
                }
            }()
            let (v, s) = try await (valuation, series)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            switch s {
            case .success(let points):
                state = .loaded(Content(valuation: v, series: points.sorted { $0.date < $1.date }))
            case .failure(let error):
                state = .loaded(Content(valuation: v, seriesError: LoadState<Content>.message(for: error)))
            }
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
        if let quote = chart.quote, gate.isCurrent(ticket) { await loadPrices(quote) }
        if gate.isCurrent(ticket), state.value != nil { await loadReturns(returnsPeriod, profileCode: profileCode) }
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
        chart = .value
        priceSeries = [:]
        returnsPeriod = .all
        returns = [:]
        notice = nil
        isSaving = false
    }

    /// Shows `chart`, loading its price series the first time (or after it failed).
    public func selectChart(_ chart: InvestmentsChart) async {
        self.chart = chart
        guard let quote = chart.quote else { return }
        if let loaded = priceSeries[quote], loaded.value != nil || loaded.isLoading { return }
        await loadPrices(quote)
    }

    /// The price chart's state; nil for the value chart.
    public var selectedPrices: LoadState<[MetalPricePoint]>? {
        chart.quote.map { priceSeries[$0] ?? .loading(previous: nil) }
    }

    // MARK: Returns

    /// Shows `period`'s returns, loading them the first time (or after they failed).
    public func selectReturns(_ period: ReturnsPeriod, profileCode: String) async {
        returnsPeriod = period
        if let loaded = returns[period], loaded.value != nil || loaded.isLoading { return }
        await loadReturns(period, profileCode: profileCode)
    }

    /// The returns card's state for the period on screen.
    public var selectedReturns: LoadState<HoldingReturns> { returns[returnsPeriod] ?? .loading(previous: nil) }

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

    private func loadPrices(_ quote: MetalQuote) async {
        let (from, to) = range
        priceSeries[quote] = .loading(previous: priceSeries[quote]?.value)
        do {
            let points = try await api.metalPriceSeries(quote: quote, from: from, to: to)
            priceSeries[quote] = .loaded(points.sorted { $0.date < $1.date })
        } catch {
            priceSeries[quote] = .failed(LoadState<[MetalPricePoint]>.message(for: error),
                                         previous: priceSeries[quote]?.value)
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
