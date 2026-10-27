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
    /// "Worth a look" and Unusual spending (PAR-9), pushed from Overview and Insights.
    public let feed: InsightFeedModel
    public let anomalies: AnomaliesModel
    /// Wealth mode's Accounts and Cash flow tabs (bank balances, writes, cash flow).
    public let cash: CashModel
    /// Wealth mode's Overview: net worth, accounts, cards owed, this month, wealth insights.
    public let wealthOverview: WealthOverviewModel
    /// Each bank account's ledger, pushed from Accounts and Wealth's Overview.
    public let accountLedgers: AccountLedgers
    /// Wealth mode's Investments tab: gold and silver, their prices and gains.
    public let investments: InvestmentsModel
    /// Structured notes: on Investments, on the account that pays for them, and their own screens.
    public let notes: NotesModel

    /// The ledger the tabs hold. The UI shows the tabs only when this equals
    /// the selected ledger, so the previous ledger's numbers never flash.
    public private(set) var activeProfile: String?
    private let live: LiveUpdates

    public init(api: any LedgerAPI, live: LiveUpdates? = nil,
                today: @escaping @Sendable () -> CalendarDay = { LedgerDates.today() },
                pendingUploads: PendingUploads? = nil,
                flushPending: (@MainActor @Sendable () async -> Int)? = nil) {
        let activity = ActivityModel(api: api)
        overview = OverviewModel(api: api)
        self.activity = activity
        insights = InsightsModel(api: api)
        budgets = BudgetsModel(api: api)
        statements = StatementsModel(api: api, pendingUploads: pendingUploads, flushPending: flushPending)
        review = ReviewModel(api: api)
        month = MonthSelection(today: today)
        categoryDrillDowns = CategoryDrillDowns(api: api)
        analysis = AnalysisScreens(api: api, today: today)
        // A spiking category is named from Activity's filter_meta, loaded with the ledger.
        feed = InsightFeedModel(api: api, categories: { activity.meta?.categories ?? [] })
        anomalies = AnomaliesModel(api: api)
        cash = CashModel(api: api, today: today)
        wealthOverview = WealthOverviewModel(api: api, today: today)
        accountLedgers = AccountLedgers(api: api, today: today,
                                        categories: { activity.meta?.assignableCategories ?? [] })
        investments = InvestmentsModel(api: api, today: today)
        notes = NotesModel(api: api, today: today)
        self.live = live ?? LiveUpdates(api: api)
        // A budget written on the Budgets tab changes Insights' budgets card.
        budgets.onChange = { [insights] code in await insights.refresh(profileCode: code) }
        // A dismissed insight leaves Overview's card; "This is fine" also dismisses its insight.
        feed.onChange = { [overview] code in await overview.refresh(profileCode: code) }
        // A balance or a new account changes net worth and the opened ledgers' balances.
        cash.onChange = { [wealthOverview, accountLedgers] code in
            await wealthOverview.refresh(profileCode: code)
            await accountLedgers.refresh(profileCode: code)
        }
        // A holding added, edited or closed, a flow or a value changes net worth; a flow paid by a
        // transaction (unlinked there) moves cash flow, Activity's spend and the ledgers.
        investments.onChange = { [wealthOverview, cash, activity, accountLedgers] code in
            await wealthOverview.refresh(profileCode: code)
            await cash.refresh(profileCode: code)
            await activity.refresh(profileCode: code)
            await accountLedgers.refresh(profileCode: code)
        }
        // A note posts its purchase, coupons and redemptions to its account, and an entry moves a
        // balance: every screen that shows money re-reads.
        notes.onChange = { [investments, wealthOverview, cash, activity, accountLedgers] code in
            await investments.refresh(profileCode: code)
            await wealthOverview.refresh(profileCode: code)
            await cash.refresh(profileCode: code)
            await activity.refresh(profileCode: code)
            await accountLedgers.refresh(profileCode: code)
        }
        // A payment linked from Activity is saving: investments, cash flow and net worth move.
        activity.onLinkChange = { [investments, cash, wealthOverview] code in
            await investments.refresh(profileCode: code)
            await cash.refresh(profileCode: code)
            await wealthOverview.refresh(profileCode: code)
        }
        // A transfer filed in a ledger moves cash flow (and Activity, when it became a purchase).
        accountLedgers.onChange = { [wealthOverview, cash, activity, investments] code in
            await wealthOverview.refresh(profileCode: code)
            await cash.refresh(profileCode: code)
            await activity.refresh(profileCode: code)
            await investments.refresh(profileCode: code)
        }
        anomalies.onChange = { [overview, feed] code in
            await overview.refresh(profileCode: code)
            await feed.refresh(profileCode: code)
        }
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
        let (feed, anomalies, cash) = (feed, anomalies, cash)
        let (wealthOverview, accountLedgers, investments, notes) = (wealthOverview, accountLedgers, investments, notes)
        await withDiscardingTaskGroup { group in
            if money { group.addTask { await overview.refresh(profileCode: code) } }
            if money { group.addTask { await feed.refresh(profileCode: code) } }
            // Balances move with bank transactions and their SMS.
            if money { group.addTask { await cash.refresh(profileCode: code) } }
            if money { group.addTask { await wealthOverview.refresh(profileCode: code) } }
            if money { group.addTask { await accountLedgers.refresh(profileCode: code) } }
            if txns { group.addTask { await anomalies.refresh(profileCode: code) } }
            // A new payment may be linked to a holding by its rule.
            if txns { group.addTask { await investments.refresh(profileCode: code) } }
            // A note's coupon or redemption is a transaction on its account.
            if txns { group.addTask { await notes.refresh(profileCode: code) } }
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
        // Prices move every 6 hours, not with Realtime: the foreground re-reads them, with the
        // transactions (a payment linked by a holding's rule).
        await refresh(after: LiveUpdates.tables)
    }

    private func clear() {
        overview.reset()
        activity.reset()
        insights.reset()
        budgets.reset()
        statements.reset()
        review.reset()
        feed.reset()
        anomalies.reset()
        cash.reset()
        wealthOverview.reset()
        accountLedgers.reset()
        investments.reset()
        notes.reset()
        month.reset()
    }
}
