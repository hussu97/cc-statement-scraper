import Foundation
import Observation

/// Wealth mode's Overview: net worth now (`net_worth`) and over time (`net_worth_series`), the bank
/// accounts (`cash_position`), this month's cash flow and the bank-account insights. Net worth is
/// the screen; the rest are extras, so one of them failing leaves its card out (or says so)
/// rather than failing the screen.
@MainActor
@Observable
public final class WealthOverviewModel {
    public struct Content: Sendable {
        public let netWorth: NetWorth
        /// Month by month, oldest first, ending with today; empty when it failed.
        public let series: [NetWorthPoint]
        /// Nil when `cash_position` failed.
        public let position: CashPosition?
        /// This month's flows; nil when `cash_flow` failed.
        public let thisMonth: CashFlowMonth?
        /// The Wealth insights (`InsightArea.wealth`), alerts first.
        public let insights: [Insight]

        public init(netWorth: NetWorth, series: [NetWorthPoint] = [], position: CashPosition? = nil,
                    thisMonth: CashFlowMonth? = nil, insights: [Insight] = []) {
            self.netWorth = netWorth
            self.series = series
            self.position = position
            self.thisMonth = thisMonth
            self.insights = insights
        }

        /// The chart, with its footnote, once there are two points to join.
        public var showsChart: Bool { NetWorthHistory.showsChart(series) }
        public var historyNote: String { NetWorthHistory.note(series) }
        /// The cards that owe something or can't say; a paid-off card is left out of the list.
        public var owingCards: [NetWorthCard] { netWorth.cards.filter { ($0.outstandingAed ?? 1) != 0 } }
    }

    /// How many months the chart asks for.
    public static let seriesMonths = 12

    public private(set) var state: LoadState<Content> = .idle
    private let api: any LedgerAPI
    private let today: @Sendable () -> CalendarDay
    private var gate = RequestGate<String>()

    public init(api: any LedgerAPI, today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() }) {
        self.api = api
        self.today = today
    }

    /// `"October 2026"`: the cash flow card's month.
    public var monthTitle: String { LedgerDates.monthTitle(today()) }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        let month = today().startOfMonth
        let api = self.api
        do {
            async let worth = api.netWorth(profileCode: profileCode)
            async let series = try? api.netWorthSeries(profileCode: profileCode, months: Self.seriesMonths)
            async let position = try? api.cashPosition(profileCode: profileCode)
            async let flow = try? api.cashFlow(profileCode: profileCode, from: month, to: month.endOfMonth)
            async let insights = try? api.insights(profileCode: profileCode)
            let (w, s, p, f, i) = try await (worth, series, position, flow, insights)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            state = .loaded(Content(
                netWorth: w,
                series: (s ?? []).sorted { $0.month < $1.month },
                position: p,
                thisMonth: f.map { CashFlow.month(month, in: CashFlow.months($0)) },
                insights: InsightFeed.sorted((i ?? []).in(.wealth))))
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Realtime, the foreground and writes elsewhere, once opened for this ledger.
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    /// Owners only (RLS `insights_owner_dismiss`); the card re-reads the insights after.
    public func dismiss(_ insight: Insight, profileCode: String) async {
        try? await api.dismissInsight(insightCode: insight.insightCode)
        await refresh(profileCode: profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
    }
}
