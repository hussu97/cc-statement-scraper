import Foundation
import Observation

/// Overview tab: the month hero, pending SMS, category ring, accounts and insights.
@MainActor
@Observable
public final class OverviewModel {
    public struct Content: Sendable {
        public let overview: Overview
        public let accounts: [AccountSummary]
        public let insights: [Insight]
    }

    public private(set) var state: LoadState<Content> = .idle
    private let api: any LedgerAPI

    public init(api: any LedgerAPI) { self.api = api }

    public func load(profileCode: String) async {
        state = state.startLoading()
        do {
            async let overview = api.overview(profileCode: profileCode, month: nil)
            async let cycles = api.statementCycles(profileCode: profileCode, limit: 24)
            async let insights = api.insights(profileCode: profileCode)
            let (o, c, i) = try await (overview, cycles, insights)
            state = .loaded(Content(
                overview: o,
                accounts: o.accounts.map { AccountSummary(account: $0, cycles: c) },
                insights: i))
        } catch {
            state = state.fail(error)
        }
    }

    public func dismiss(_ insight: Insight, profileCode: String) async {
        try? await api.dismissInsight(insightCode: insight.insightCode)
        await load(profileCode: profileCode)
    }
}

extension Overview {
    public var monthTitle: String { LedgerDates.monthTitle(month) }
    public var heroAmount: String { MoneyFormat.hero(spend) }
    public var comparison: (text: String, tone: Tone) {
        SpendComparison.versusAverage(spend: spend, average: spendAvg3m)
    }
    public var paceText: String {
        SpendComparison.versusLastMonthToDate(spend: spend, previous: spendPrevMonthToDate)
    }

    /// The live strip under the hero: `"2 pending · AED 145.00"`, or nil when none.
    public var pendingSummary: String? {
        guard pendingCount > 0 else { return nil }
        return "\(pendingCount) pending · \(MoneyFormat.aed(pendingAmount))"
    }

    /// `"Last SMS 14:05"` / `"Last SMS 3 Oct"`.
    public func lastSMSLabel(today: CalendarDay = LedgerDates.today()) -> String? {
        guard let at = lastSmsAt else { return nil }
        let day = CalendarDay(date: at)
        return day == today ? "Last SMS \(LedgerDates.timeLabel(at))" : "Last SMS \(LedgerDates.dayLabel(day, today: today))"
    }

    /// Categories with a positive amount — the ring cannot draw a refund-heavy
    /// (negative) slice.
    public var ringCategories: [TopCategory] { topCategories.filter { $0.amount > 0 } }
}
