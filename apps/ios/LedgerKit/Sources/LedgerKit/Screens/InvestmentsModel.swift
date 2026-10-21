import Foundation
import Observation

/// What the Investments chart draws: the holdings' value against their cost, or a price.
public enum InvestmentsChart: String, CaseIterable, Identifiable, Hashable, Sendable {
    case value, gold24k, silver

    public var id: String { rawValue }

    /// The segmented control: `"Value"`, `"24K gold"`, `"Silver"`.
    public var title: String {
        switch self {
        case .value: "Value"
        case .gold24k: "24K gold"
        case .silver: "Silver"
        }
    }

    /// The price series behind a price chart; nil for the value chart.
    public var quote: MetalQuote? {
        switch self {
        case .value: nil
        case .gold24k: .gold24k
        case .silver: .silverRetail
        }
    }

    /// Under the chart.
    public var note: String {
        switch self {
        case .value:
            "Today's holdings at each day's Dubai retail prices, against what you paid for them (holdings with a cost)."
        case .gold24k: "Dubai retail 24K gold (999.9), AED per gram, each day's last price."
        case .silver: "Dubai retail silver, AED per gram, each day's last price."
        }
    }

    /// How many days every chart covers.
    public static let days = 90

    /// The value chart's known days, oldest first.
    public static func known(_ points: [HoldingValuePoint]) -> [HoldingValuePoint] {
        points.filter { $0.valueAed != nil }.sorted { $0.date < $1.date }
    }

    /// A price chart's known days, oldest first.
    public static func known(_ points: [MetalPricePoint]) -> [MetalPricePoint] {
        points.filter { $0.aedPerGram != nil }.sorted { $0.date < $1.date }
    }

    /// A y-axis tick (a chart position, not money): compact AED (`"650k"`, `"496"`), or two
    /// decimals under 100, where silver's price per gram moves in fils (`"7.96"`).
    public static func axisLabel(_ tick: Double) -> String {
        if abs(tick) < 100 { return MoneyFormat.grouped(Decimal(Int((tick * 100).rounded())) / 100, fractionDigits: 2) }
        return MoneyFormat.compact(Decimal(Int(tick.rounded())))
    }

    /// Instead of a chart: two known days make a line.
    public static let tooFewMessage = "Not enough price history yet: a line shows from the second day of prices."
}

/// Wealth mode's Investments tab: gold and silver valued by the server (`holdings_valuation`), the
/// 90-day value against cost (`holdings_value_series`) or a price (`metal_price_series`), and Add,
/// Edit and Close for owners. Every figure is the server's; the model only loads and words them.
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
    public func newDraft() -> HoldingDraft { HoldingDraft(today: today()) }
    public func draft(for holding: Holding) -> HoldingDraft { HoldingDraft(holding: holding, today: today()) }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        if !sameKey { priceSeries = [:] }
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
        await refresh(profileCode: profileCode)
        await onChange?(profileCode)
        return nil
    }
}
