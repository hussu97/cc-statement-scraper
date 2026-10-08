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

    public var period: Period = .sixMonths
    public private(set) var state: LoadState<Content> = .idle
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    /// From the first day of the month `months - 1` ago through today.
    public nonisolated static func range(for period: Period, today: CalendarDay = LedgerDates.today()) -> (from: CalendarDay, to: CalendarDay) {
        (today.startOfMonth.adding(months: -(period.months - 1)), today)
    }

    public func load(profileCode: String) async {
        state = state.startLoading()
        let (from, to) = Self.range(for: period)
        do {
            async let trend = api.spendSeries(profileCode: profileCode, from: from, to: to, grain: .month, group: .none)
            async let categories = api.categoryBreakdown(profileCode: profileCode, from: from, to: to)
            async let merchants = api.merchantLeaderboard(profileCode: profileCode, from: from, to: to, limit: 10)
            async let recurring = api.recurringList(profileCode: profileCode)
            async let budgets = api.budgetStatus(profileCode: profileCode, month: nil)
            state = .loaded(try await Content(trend: trend, categories: categories, merchants: merchants,
                                              recurring: recurring, budgets: budgets))
        } catch {
            state = state.fail(error)
        }
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
