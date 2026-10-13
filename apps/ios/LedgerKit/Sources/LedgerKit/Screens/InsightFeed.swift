import Foundation
import Observation

/// Where an insight leads (the web's `insightTarget`, WEB-25): the screen that answers it.
public enum InsightLink: Hashable, Sendable {
    /// The Budgets tab.
    case budgets
    /// Settings → Statements (the web's Cards → Statements).
    case statements
    /// The Insights tab's recurring charges (the web's Subscriptions tab).
    case subscriptions
    /// The Insights tab's trend (the web's Trends tab).
    case trends
    /// The Insights tab's categories (a category spike without a category the app knows).
    case categories
    /// A category's drill-down, pushed where the link is.
    case category(CategoryDrillDownRequest)
    /// Activity with these filters.
    case activity(ActivityQuery)
    /// Activity with one transaction's sheet open.
    case transaction(txnCode: String)
    /// Overview → Review.
    case review

    public var label: String {
        switch self {
        case .budgets: "See budgets"
        case .statements: "See statements"
        case .subscriptions: "See subscriptions"
        case .trends: "See trends"
        case .categories: "See categories"
        case .category: "See the category"
        case .activity(let query): query.uncategorizedOnly ? "Categorise them" : "See activity"
        case .transaction: "See transaction"
        case .review: "Open review"
        }
    }

    /// Lands on the Insights tab's own first screen: from a screen pushed on that tab the link
    /// goes back to it; from another tab it switches to Insights.
    public var opensInsights: Bool {
        switch self {
        case .subscriptions, .trends, .categories: true
        default: false
        }
    }
}

extension TabRouter {
    /// Follows a link that changes tab (every link but `.category`, which the screen pushes).
    public func follow(_ link: InsightLink) {
        switch link {
        case .budgets: show(.budgets)
        case .statements: openStatements()
        case .subscriptions, .trends, .categories: show(.insights)
        case .activity(let query): openActivity(query)
        case .transaction(let code): openTransaction(code)
        case .review: open(.review, ledgerOnScreen: true)
        case .category: break
        }
    }
}

extension Insight {
    /// The screen that answers this insight; nil for a kind this build doesn't know, so a new
    /// server kind never links somewhere wrong. `categories` names a spiking category
    /// (`filter_meta`); `today` dates "this month".
    public func link(categories: [FilterMeta.CategoryOption], today: CalendarDay = LedgerDates.today()) -> InsightLink? {
        switch kind {
        case "budget_risk": return .budgets
        case "statement_due": return .statements
        case "price_change", "new_recurring": return .subscriptions
        case "uncategorized":
            var query = ActivityQuery()
            query.uncategorizedOnly = true
            return .activity(query)
        case "category_spike":
            // "So far this month": the category from the 1st to today (the web's `range: this_month`).
            guard let code = data.categoryCode, let option = categories.first(where: { $0.categoryCode == code })
            else { return .categories }
            let target = CategoryTarget(categoryCode: code, name: option.name, colorToken: option.colorToken)
            return .category(CategoryDrillDownRequest(target: target, from: today.startOfMonth, to: today))
        case "large_transaction":
            return data.txnCode.map { .transaction(txnCode: $0) } ?? .activity(ActivityQuery())
        case "review_backlog": return .review
        case "spend_pace": return .trends
        default: return nil
        }
    }

    /// `"Noticed today"`, `"Noticed yesterday"`, `"Noticed 8 Oct"` (Dubai days).
    public func noticedLabel(today: CalendarDay = LedgerDates.today()) -> String {
        let day = LedgerDates.relativeDayLabel(CalendarDay(date: createdAt), today: today)
        return "Noticed " + (day == "Today" || day == "Yesterday" ? day.lowercased() : day)
    }

    /// VoiceOver's name for the severity mark (the web's `SEVERITY_LABEL`).
    public var severityLabel: String {
        switch severity {
        case "alert": "Alert"
        case "warn": "Heads-up"
        default: "Info"
        }
    }
}

/// One section of the "Worth a look" feed: the insights one screen answers.
public struct InsightFeedGroup: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let items: [Insight]

    /// "3 to look at".
    public var countLabel: String { "\(items.count) to look at" }
}

/// The feed's sections and their order (the web's `INSIGHT_GROUPS`, MA-5).
public enum InsightFeed {
    public static let groups: [(key: String, label: String, kinds: [String])] = [
        ("spending", "Spending", ["spend_pace", "category_spike", "large_transaction"]),
        ("budgets", "Budgets", ["budget_risk"]),
        ("subscriptions", "Subscriptions", ["price_change", "new_recurring"]),
        ("statements", "Statements", ["statement_due"]),
        ("tidy", "To tidy up", ["uncategorized", "review_backlog"]),
    ]

    /// Open insights read at most (the web's `INSIGHTS_LIMIT`): Overview shows the first few,
    /// the feed all of them.
    public static let limit = 100

    /// Insights in sections, in `groups` order, each alerts first; a kind this build doesn't know
    /// lands in "Other" at the end rather than disappearing. Empty sections are left out.
    public static func group(_ insights: [Insight]) -> [InsightFeedGroup] {
        var buckets = groups.map { (key: $0.key, label: $0.label, kinds: $0.kinds, items: [Insight]()) }
        var other: [Insight] = []
        for insight in insights {
            if let i = buckets.firstIndex(where: { $0.kinds.contains(insight.kind) }) {
                buckets[i].items.append(insight)
            } else {
                other.append(insight)
            }
        }
        let all = buckets.map { ($0.key, $0.label, $0.items) } + [("other", "Other", other)]
        return all.filter { !$0.2.isEmpty }.map { InsightFeedGroup(key: $0.0, label: $0.1, items: sorted($0.2)) }
    }

    /// Alerts, then heads-ups, then the rest; newest first within a severity.
    public static func sorted(_ insights: [Insight]) -> [Insight] {
        func rank(_ severity: String) -> Int { ["alert": 0, "warn": 1, "info": 2][severity] ?? 3 }
        return insights.sorted {
            rank($0.severity) != rank($1.severity) ? rank($0.severity) < rank($1.severity) : $0.createdAt > $1.createdAt
        }
    }
}

/// "Worth a look" (PAR-9, the web's Insights → Worth a look): every open insight, in sections
/// by the screen that answers it, each linking there. Owners dismiss one; it leaves the feed at
/// once and Overview's card on its next load (`onChange`).
@MainActor
@Observable
public final class InsightFeedModel {
    public private(set) var state: LoadState<[Insight]> = .idle
    private let api: any LedgerAPI
    private let categories: @MainActor () -> [FilterMeta.CategoryOption]
    private var gate = RequestGate<String>()
    /// Called with the ledger after a dismissal: Overview's card shows the same insights.
    @ObservationIgnored public var onChange: (@MainActor (String) async -> Void)?

    /// `categories` names a spiking category for its link (Activity's `filter_meta`).
    public init(api: any LedgerAPI, categories: @escaping @MainActor () -> [FilterMeta.CategoryOption] = { [] }) {
        self.api = api
        self.categories = categories
    }

    public var hasLoaded: Bool { gate.requested != nil }

    /// The feed's sections; nil until loaded.
    public var groups: [InsightFeedGroup]? { state.value.map(InsightFeed.group) }

    /// The way in from Insights: "4 to look at" / "All quiet" once read, else what the feed is.
    public var summary: String {
        guard let count = state.value?.count else { return "What the nightly check noticed" }
        return count == 0 ? "All quiet" : "\(count) to look at"
    }

    /// The read hit its limit: "Showing the newest 100 insights."
    public var limitNote: String? {
        (state.value?.count ?? 0) >= InsightFeed.limit ? "Showing the newest \(InsightFeed.limit) insights." : nil
    }

    public func link(for insight: Insight, today: CalendarDay = LedgerDates.today()) -> InsightLink? {
        insight.link(categories: categories(), today: today)
    }

    public func load(profileCode: String) async {
        let (ticket, sameKey) = gate.begin(profileCode)
        state = sameKey ? state.startLoading() : .loading(previous: nil)
        do {
            let rows = try await api.insights(profileCode: profileCode)
            guard gate.isCurrent(ticket) else { return }
            gate.finish(profileCode)
            state = .loaded(rows)
        } catch {
            guard gate.isCurrent(ticket) else { return }
            state = state.fail(error)
        }
    }

    public func loadIfNeeded(profileCode: String) async {
        guard gate.requested != profileCode || state.value == nil && !state.isLoading else { return }
        await load(profileCode: profileCode)
    }

    /// Realtime / foreground, once opened for this ledger.
    public func refresh(profileCode: String) async {
        guard gate.requested == profileCode else { return }
        await load(profileCode: profileCode)
    }

    /// Owners only (RLS `insights_owner_dismiss`); the screen hides the button for others.
    /// Gone from the feed at once; a failed write brings it back with the server's list.
    public func dismiss(_ insight: Insight, profileCode: String) async {
        if case .loaded(let rows) = state {
            state = .loaded(rows.filter { $0.insightCode != insight.insightCode })
        }
        try? await api.dismissInsight(insightCode: insight.insightCode)
        await refresh(profileCode: profileCode)   // not if the reader switched ledger meanwhile
        await onChange?(profileCode)
    }

    public func reset() {
        gate.reset()
        state = .idle
    }
}
