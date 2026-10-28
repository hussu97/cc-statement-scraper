import Foundation
import Observation

/// India mode (Zerodha Kite and Coin, in rupees): `india_overview` for the ledger, which says
/// whether India is offered at all (`available`, `tabs`) and gives the Overview its figures, and
/// for one period (30 days, 90 days, YTD, 365 days) the value against invested and the period's
/// growth. Kite and Coin's tabs are those accounts' `AccountLedgerModel`s (`account(for:)` names
/// the account). Every figure is the server's; the model only loads it.
@MainActor
@Observable
public final class IndiaModel {
    /// The last full read (any period): availability, the hero and the accounts.
    public private(set) var state: LoadState<IndiaOverview> = .idle
    /// The period the chart and the period block show.
    public private(set) var period: ReturnsPeriod = .ninetyDays
    /// Each period's read, loaded when first shown (and again on a reload).
    public private(set) var periods: [ReturnsPeriod: LoadState<IndiaOverview>] = [:]
    /// Runs after each read that answered, with the ledger's India tabs (`IndiaOverview.tabs`;
    /// empty without India) and the ledger: the tab router offers or withdraws India.
    @ObservationIgnored public var onLoaded: (@MainActor ([LedgerTab], String) -> Void)?

    private let api: any LedgerAPI
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI) {
        self.api = api
    }

    /// The chart and period block's read for the period on screen.
    public var selected: LoadState<IndiaOverview> { periods[period] ?? .loading(previous: nil) }

    /// The account a Kite or Coin tab shows; nil until read, or when the ledger has none.
    public func account(for tab: LedgerTab) -> IndiaOverview.Account? { state.value?.account(for: tab) }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        // Other periods re-read when next shown; the one on screen keeps its figures while it reloads.
        periods = sameKey ? periods.filter { $0.key == period } : [:]
        let period = self.period
        periods[period] = .loading(previous: periods[period]?.value)
        do {
            let overview = try await api.indiaOverview(profileCode: profileCode, period: period)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            state = .loaded(overview)
            periods[period] = .loaded(overview)
            onLoaded?(overview.tabs, profileCode)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
            periods[period] = .failed(LoadState<IndiaOverview>.message(for: error), previous: periods[period]?.value)
        }
    }

    /// Loads unless this ledger is already on screen or loading.
    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Reloads what was read (foreground, a sync), if anything was.
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    /// Shows `period`'s chart and figures, reading them the first time (or after a failure).
    public func select(_ period: ReturnsPeriod, profileCode: String) async {
        self.period = period
        guard periods[period].map({ $0.value == nil && !$0.isLoading }) ?? true else { return }
        periods[period] = .loading(previous: nil)
        do {
            let overview = try await api.indiaOverview(profileCode: profileCode, period: period)
            guard gate.requested == profileCode else { return }
            periods[period] = .loaded(overview)
        } catch {
            guard gate.requested == profileCode else { return }
            periods[period] = .failed(LoadState<IndiaOverview>.message(for: error), previous: nil)
        }
    }

    public func reset() {
        gate.reset()
        state = .idle
        period = .ninetyDays
        periods = [:]
    }
}
