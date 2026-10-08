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
            async let insights = api.insights(profileCode: profileCode)
            let (o, i) = try await (overview, insights)
            state = .loaded(Content(
                overview: o,
                accounts: o.accounts.map { AccountSummary(account: $0) },
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

    /// `"October 2026 · posted so far"` — the hero counts posted spend; pending
    /// alerts are listed under it, not in it.
    public func heroEyebrow(today: CalendarDay = LedgerDates.today()) -> String {
        isCurrentMonth(today: today) ? "\(monthTitle) · posted so far" : monthTitle
    }

    public func isCurrentMonth(today: CalendarDay = LedgerDates.today()) -> Bool {
        month.year == today.year && month.month == today.month
    }

    /// The hero chip. The current month is compared with the same day last
    /// month; a completed month with its 3-month average. Ratios are the server's.
    public func comparison(today: CalendarDay = LedgerDates.today()) -> (text: String, tone: Tone)? {
        if isCurrentMonth(today: today) {
            return SpendComparison.versusSameDayLastMonth(change: changeVsPrevMonthToDate, spend: spend,
                                                          previous: spendPrevMonthToDate)
        }
        return SpendComparison.versusAverage(change: changeVsAvg3m)
    }

    /// Reference figures under the chip, as the server returned them.
    /// `["Same day last month AED 2,100", "3-month average AED 9,000 a month"]`.
    public var referenceLines: [String] {
        var lines = ["Same day last month \(MoneyFormat.aed(spendPrevMonthToDate, fractionDigits: 0))"]
        if spendAvg3m > 0 { lines.append("3-month average \(MoneyFormat.aed(spendAvg3m, fractionDigits: 0)) a month") }
        return lines
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

    /// The "Needs attention" rows: open reviews first (they link to Review).
    public var attention: [AttentionItem] {
        var items: [AttentionItem] = []
        if openReviews > 0 {
            items.append(AttentionItem(kind: .reviews, count: openReviews,
                                       title: openReviews == 1 ? "1 item to review" : "\(openReviews) items to review",
                                       detail: "Unknown cards and uncertain matches"))
        }
        if uncategorizedCount > 0 {
            items.append(AttentionItem(kind: .uncategorized, count: uncategorizedCount,
                                       title: uncategorizedCount == 1 ? "1 uncategorised this month"
                                           : "\(uncategorizedCount) uncategorised this month",
                                       detail: "Tap a row in Activity to categorise it"))
        }
        return items
    }
}

/// A row of Overview's "Needs attention" card.
public struct AttentionItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case reviews, uncategorized }
    public var id: Kind { kind }
    public let kind: Kind
    public let count: Int
    public let title: String
    public let detail: String
}
