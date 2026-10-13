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
        /// The empty-ledger checklist, shown instead of the hero; nil for a ledger with data.
        public let setup: SetupChecklist?
    }

    public private(set) var state: LoadState<Content> = .idle
    private let api: any LedgerAPI
    private var gate = RequestGate<Key>()

    struct Key: Hashable, Sendable {
        let profileCode: String
        let month: CalendarDay?
    }

    /// Called after each successful load with the ledger it was for: the app
    /// writes the widgets' snapshot from it (N-2).
    @ObservationIgnored public var onLoaded: (@MainActor (Overview, _ profileCode: String) -> Void)?

    public init(api: any LedgerAPI) { self.api = api }

    /// The month on screen or loading (nil: the current month).
    public var month: CalendarDay? { gate.requested?.month }

    /// `month` nil is the current month. A refresh of the same ledger and month
    /// keeps the figures on screen; another month or ledger shows a spinner
    /// rather than the previous month's numbers under the new title.
    public func load(profileCode: String, month: CalendarDay? = nil) async {
        let key = Key(profileCode: profileCode, month: month)
        let (ticket, sameKey) = gate.begin(key)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        do {
            async let overview = api.overview(profileCode: profileCode, month: month)
            async let insights = api.insights(profileCode: profileCode)
            let (o, i) = try await (overview, insights)
            let setup = await Self.setupChecklist(for: o, profileCode: profileCode, api: api)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(key)
            state = .loaded(Content(
                overview: o,
                accounts: o.accounts.map { AccountSummary(account: $0) },
                insights: i,
                setup: setup))
            onLoaded?(o, profileCode)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    /// The checklist of an empty ledger. Its two extra reads (any upload, how
    /// many members) run only for an empty ledger; a failed one leaves that
    /// step unknown rather than failing Overview.
    static func setupChecklist(for overview: Overview, profileCode: String,
                               api: any LedgerAPI) async -> SetupChecklist? {
        guard SetupChecklist.isEmptyLedger(overview) else { return nil }
        async let firstUpload = try? api.documents(profileCode: profileCode, page: PageRequest(offset: 0, limit: 1))
        async let members = try? api.memberCount(profileCode: profileCode)
        let (page, count) = await (firstUpload, members)
        return SetupChecklist.make(overview: overview, uploads: page.map { $0.total ?? $0.items.count }, members: count)
    }

    /// Loads unless this ledger and month are already on screen or loading
    /// (a tab re-appearing, or the month switcher and the ledger switch both asking).
    public func loadIfNeeded(profileCode: String, month: CalendarDay?) async {
        guard gate.requested != Key(profileCode: profileCode, month: month) || state.value == nil && !state.isLoading
        else { return }
        await load(profileCode: profileCode, month: month)
    }

    /// Realtime / foreground: reloads the month on screen.
    public func refresh(profileCode: String) async {
        guard let requested = gate.requested, requested.profileCode == profileCode else { return }
        await load(profileCode: profileCode, month: requested.month)
    }

    public func dismiss(_ insight: Insight, profileCode: String) async {
        try? await api.dismissInsight(insightCode: insight.insightCode)
        await load(profileCode: profileCode, month: month)
    }

    /// Another ledger or sign-out: nothing from the old one stays on screen.
    public func reset() {
        gate.reset()
        state = .idle
    }
}

extension Overview {
    public var monthTitle: String { LedgerDates.monthTitle(month) }
    public var heroAmount: String { MoneyFormat.hero(spend) }

    /// The ring card's trailing label: `"This month"` / `"September 2026"`.
    public func scopeLabel(today: CalendarDay = LedgerDates.today()) -> String {
        LedgerDates.monthScopeLabel(month, today: today)
    }

    /// Pending alerts and the latest transactions are about now, not about the
    /// month on screen: shown on the current month only.
    public func showsLiveSections(today: CalendarDay = LedgerDates.today()) -> Bool {
        isCurrentMonth(today: today)
    }

    /// `"No spending this month yet."` / `"No spending in September."`.
    public func emptyCategoriesMessage(today: CalendarDay = LedgerDates.today()) -> String {
        isCurrentMonth(today: today)
            ? "No spending this month yet."
            : "No spending \(LedgerDates.monthPhrase(month, today: today))."
    }

    /// `"October 2026 · posted so far"` — the hero counts posted spend; pending
    /// alerts are listed under it, not in it.
    public func heroEyebrow(today: CalendarDay = LedgerDates.today()) -> String {
        isCurrentMonth(today: today) ? "\(monthTitle) · posted so far" : monthTitle
    }

    /// The hero (eyebrow, "AED" and the number) as one VoiceOver element:
    /// `"October spend, posted so far, 860 dirhams"`; a past month
    /// `"September spend, 8,450 dirhams"`, with the year outside this one.
    public func heroAccessibilityLabel(today: CalendarDay = LedgerDates.today()) -> String {
        let name = month.year == today.year ? LedgerDates.monthName(month) : monthTitle
        let scope = isCurrentMonth(today: today) ? "\(name) spend, posted so far" : "\(name) spend"
        let pending = heroPendingAmount(today: today).map { ", plus \(MoneyFormat.spokenDirhams($0)) pending" } ?? ""
        return "\(scope), \(MoneyFormat.spokenDirhams(spend))\(pending)"
    }

    /// The hero's pending line (UX-1r): `"+ AED 3,105 pending"`, from the
    /// server's `pending_amount` and `pending_count`, never a sum on the phone.
    /// The hero number is posted spend, so pending is shown beside it, not
    /// folded in. Current month only (pending alerts are about now); nil when
    /// nothing is pending. Pending charges with no AED rate yet aren't in the
    /// amount: a count stands in when that leaves nothing to show.
    public func heroPendingLine(today: CalendarDay = LedgerDates.today()) -> String? {
        guard isCurrentMonth(today: today), pendingCount > 0 else { return nil }
        if let amount = heroPendingAmount(today: today) {
            return "+ \(MoneyFormat.aed(amount, fractionDigits: 0)) pending"
        }
        return pendingCount == 1 ? "+ 1 pending charge" : "+ \(pendingCount) pending charges"
    }

    private func heroPendingAmount(today: CalendarDay) -> Decimal? {
        isCurrentMonth(today: today) && pendingCount > 0 && pendingAmount > 0 ? pendingAmount : nil
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
    /// A completed month shows the whole previous month instead:
    /// `["August AED 7,400", "3-month average …"]`.
    public var referenceLines: [String] { referenceLines() }

    public func referenceLines(today: CalendarDay = LedgerDates.today()) -> [String] {
        let previous = month.adding(months: -1)
        let first = isCurrentMonth(today: today)
            ? "Same day last month \(MoneyFormat.aed(spendPrevMonthToDate, fractionDigits: 0))"
            : "\(previous.year == today.year ? LedgerDates.monthName(previous) : LedgerDates.monthTitle(previous)) "
                + MoneyFormat.aed(spendPrevMonth, fractionDigits: 0)
        var lines = [first]
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
    /// Reviews are ledger-wide; the uncategorised count is the month's.
    public var attention: [AttentionItem] { attention() }

    public func attention(today: CalendarDay = LedgerDates.today()) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if openReviews > 0 {
            items.append(AttentionItem(kind: .reviews, count: openReviews,
                                       title: openReviews == 1 ? "1 item to review" : "\(openReviews) items to review",
                                       detail: "Unknown cards and uncertain matches"))
        }
        if uncategorizedCount > 0 {
            items.append(AttentionItem(kind: .uncategorized, count: uncategorizedCount,
                                       title: "\(uncategorizedCount) uncategorised \(LedgerDates.monthPhrase(month, today: today))",
                                       detail: "Tap to see them in Activity and categorise them"))
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
