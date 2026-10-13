import Foundation
import Observation

/// The data screens of one ledger (four data tabs, plus Statements under Settings and Review), kept pointed at the selected profile:
/// switching ledger clears every tab before anything of the new one shows
/// (BACKLOG IOS-14), Realtime and the foreground refresh every tab the reader
/// has opened (IOS-13), and the month on screen is shared by Overview and
/// Insights.
@MainActor
@Observable
public final class LedgerScreens {
    public let overview: OverviewModel
    public let activity: ActivityModel
    public let insights: InsightsModel
    public let budgets: BudgetsModel
    public let statements: StatementsModel
    public let review: ReviewModel
    public let month: MonthSelection
    /// Makes the category drill-down's model, for whichever tab pushes it.
    public let categoryDrillDowns: CategoryDrillDowns
    /// Makes the loaders of Insights' "More analysis" screens (PAR-12).
    public let analysis: AnalysisScreens

    /// The ledger the tabs hold. The UI shows the tabs only when this equals
    /// the selected ledger, so the previous ledger's numbers never flash.
    public private(set) var activeProfile: String?
    private let live: LiveUpdates

    public init(api: any LedgerAPI, live: LiveUpdates? = nil,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                pendingUploads: PendingUploads? = nil,
                flushPending: (@MainActor @Sendable () async -> Int)? = nil) {
        overview = OverviewModel(api: api)
        activity = ActivityModel(api: api)
        insights = InsightsModel(api: api)
        budgets = BudgetsModel(api: api)
        statements = StatementsModel(api: api, pendingUploads: pendingUploads, flushPending: flushPending)
        review = ReviewModel(api: api)
        month = MonthSelection(today: today)
        categoryDrillDowns = CategoryDrillDowns(api: api)
        analysis = AnalysisScreens(api: api, today: today)
        self.live = live ?? LiveUpdates(api: api)
        // A budget written on the Budgets tab changes Insights' budgets card.
        budgets.onChange = { [insights] code in await insights.refresh(profileCode: code) }
    }

    /// Points every tab at `code` (clearing them first when it is another
    /// ledger), loads Overview and Activity, and follows Realtime.
    public func select(_ code: String) async {
        if activeProfile != code {
            clear()
            activeProfile = code
            live.start(profileCode: code) { [weak self] tables in
                guard let self, self.activeProfile == code else { return }
                await self.refresh(after: tables)
            }
        }
        async let a: Void = overview.loadIfNeeded(profileCode: code, month: month.requestMonth)
        async let b: Void = activity.loadIfNeeded(profileCode: code)
        _ = await (a, b)
        if activeProfile == code { month.setFirstDay(activity.meta?.dateRange?.min) }
    }

    /// Sign-out: stop following and forget every tab.
    public func stop() {
        live.stop()
        clear()
        activeProfile = nil
    }

    /// Refreshes the tabs that show any of `tables`, if they have been opened.
    public func refresh(after tables: Set<String>) async {
        guard let code = activeProfile else { return }
        let money = !tables.isDisjoint(with: ["transactions", "sms_messages", "insights"])
        let txns = tables.contains("transactions")
        let docs = tables.contains("documents")
        let reviews = !tables.isDisjoint(with: ["transactions", "sms_messages", "documents"])
        let (overview, activity, insights, budgets, statements, review) = (overview, activity, insights, budgets, statements, review)
        await withDiscardingTaskGroup { group in
            if money { group.addTask { await overview.refresh(profileCode: code) } }
            if txns {
                group.addTask { await activity.refresh(profileCode: code) }
                group.addTask { await insights.refresh(profileCode: code) }
                group.addTask { await budgets.refresh(profileCode: code) }
            }
            if docs || txns { group.addTask { await statements.refresh(profileCode: code) } }
            if reviews { group.addTask { await review.refresh(profileCode: code) } }
        }
    }

    /// Back in the foreground: every opened tab, Insights included.
    public func refreshAll() async {
        await refresh(after: LiveUpdates.tables)
    }

    private func clear() {
        overview.reset()
        activity.reset()
        insights.reset()
        budgets.reset()
        statements.reset()
        review.reset()
        month.reset()
    }
}
