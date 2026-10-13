import Foundation
import Observation

/// Insights tab: monthly trend, categories, merchants, recurring and budgets.
@MainActor
@Observable
public final class InsightsModel {
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case threeMonths = "3M", sixMonths = "6M", twelveMonths = "12M"
        public var id: String { rawValue }
        public var months: Int {
            switch self {
            case .threeMonths: 3
            case .sixMonths: 6
            case .twelveMonths: 12
            }
        }
    }

    public struct Content: Sendable {
        public let trend: [SpendPoint]
        public let categories: [CategorySpend]
        public let merchants: [MerchantSpend]
        public let recurring: [RecurringCharge]
        public let budgets: [BudgetStatus]
    }

    /// Top merchants Insights lists (`merchant_leaderboard`'s `p_limit`, BACKLOG PAR-8).
    public static let merchantLimit = 20

    public var period: Period = .sixMonths
    public private(set) var state: LoadState<Content> = .idle
    private let api: any LedgerAPI
    private var gate = RequestGate<Key>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let period: Period
        let month: CalendarDay?
    }

    public init(api: any LedgerAPI) { self.api = api }

    /// Something has been loaded (or is loading) — a foreground refresh only
    /// reloads tabs the reader has opened.
    public var hasLoaded: Bool { gate.requested != nil }

    /// The month the period ends in (nil: the current month).
    public var month: CalendarDay? { gate.requested?.month }

    /// The `period.months` months ending with `month`: from the first day of
    /// the earliest through the month's last day, or through today for the
    /// current month.
    public nonisolated static func range(for period: Period, month: CalendarDay? = nil,
                                         today: CalendarDay = LedgerDates.today()) -> (from: CalendarDay, to: CalendarDay) {
        let end = (month ?? today).startOfMonth
        let to = end == today.startOfMonth ? today : min(end.endOfMonth, today)
        return (end.adding(months: -(period.months - 1)), to)
    }

    /// The budgets card's trailing label: `"This month"` / `"September 2026"`.
    public func budgetsScope(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.monthScopeLabel(month ?? today, today: today)
    }

    public func load(profileCode: String, month: CalendarDay? = nil) async {
        let key = Key(profileCode: profileCode, period: period, month: month)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        let (from, to) = Self.range(for: period, month: month)
        do {
            async let trend = api.spendSeries(profileCode: profileCode, from: from, to: to, grain: .month, group: .none)
            async let categories = api.categoryBreakdown(profileCode: profileCode, from: from, to: to)
            async let merchants = api.merchantLeaderboard(profileCode: profileCode, from: from, to: to,
                                                             limit: Self.merchantLimit)
            async let recurring = api.recurringList(profileCode: profileCode)
            async let budgets = api.budgetStatus(profileCode: profileCode, month: month)
            let content = try await Content(trend: trend, categories: categories, merchants: merchants,
                                            recurring: recurring, budgets: budgets)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            state = .loaded(content)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// Loads unless this ledger, period and month are already on screen or loading.
    public func loadIfNeeded(profileCode: String, month: CalendarDay?) async {
        let key = Key(profileCode: profileCode, period: period, month: month)
        guard gate.requested != key || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode, month: month)
    }

    /// Reloads what is on screen (foreground, Realtime), if anything is.
    public func refresh(profileCode: String) async {
        guard let requested = gate.requested, requested.profileCode == profileCode else { return }
        await load(profileCode: profileCode, month: requested.month)
    }

    public func reset() {
        gate.reset()
        state = .idle
    }
}

extension InsightsModel {
    /// `"Last 6 months to September 2026"` — what the period picker covers.
    public nonisolated static func periodCaption(_ period: Period, month: CalendarDay?,
                                                 today: CalendarDay = LedgerDates.today()) -> String {
        let end = (month ?? today).startOfMonth
        let tail = end == today.startOfMonth ? "to today" : "to \(LedgerDates.monthTitle(end))"
        return "Last \(period.months) months \(tail)"
    }
}

extension InsightsModel.Content {
    /// Active recurring charges, soonest next charge first.
    public var activeRecurring: [RecurringCharge] {
        recurring.filter { $0.status == "active" }
    }

    /// Server-computed yearly cost of active subscriptions, summed for the header.
    public var recurringAnnualTotal: Decimal {
        activeRecurring.reduce(0) { $0 + $1.annualCost }
    }
}
