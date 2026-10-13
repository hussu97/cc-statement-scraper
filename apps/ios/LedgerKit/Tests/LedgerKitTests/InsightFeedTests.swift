import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private let dining = "cat_01hzy3k8w9m2n4p6q8r0s2t4d1"
private let categories = [
    FilterMeta.CategoryOption(categoryCode: dining, name: "Dining", kind: "expense", colorToken: "chart-3",
                              parentCode: nil, archived: false),
]

private func insights() throws -> [Insight] {
    try LedgerJSON.decode([Insight].self, from: try fixture("insights"))
}

@Suite("Worth a look (PAR-9): insights decode, link like the web and group by screen")
struct InsightFeedTests {
    @Test("an insights row decodes with the codes its link needs; a malformed code or shape is dropped")
    func decoding() throws {
        let rows = try insights()
        #expect(rows.count == 8)
        #expect(rows[0].data.txnCode == "txn_01hzy3k8w9m2n4p6q8r0s2t4v6")
        #expect(rows[1].data.categoryCode == dining)
        #expect(rows[2].data.stmtCode == "stm_01hzy3k8w9m2n4p6q8r0s2t4v6")
        #expect(rows[2].validUntil == day("2026-10-16"))
        #expect(rows[6].data.txnCode == nil)              // "not a code"
        #expect(rows[7].data == InsightData())            // `data` an array: no codes, still listed
    }

    @Test("each kind links where the web's insightTarget does")
    func links() throws {
        let rows = try insights()
        let today = day("2026-10-14")
        func link(_ i: Int) -> InsightLink? { rows[i].link(categories: categories, today: today) }

        #expect(link(0) == .transaction(txnCode: "txn_01hzy3k8w9m2n4p6q8r0s2t4v6"))
        let target = CategoryTarget(categoryCode: dining, name: "Dining", colorToken: "chart-3")
        #expect(link(1) == .category(CategoryDrillDownRequest(target: target, from: day("2026-10-01"), to: today)))
        #expect(link(2) == .statements)
        #expect(link(3) == .budgets)
        var uncategorised = ActivityQuery()
        uncategorised.uncategorizedOnly = true
        #expect(link(4) == .activity(uncategorised))
        #expect(link(5) == .subscriptions)
        #expect(link(6) == .activity(ActivityQuery()))   // no usable code: Activity, not a wrong row
        #expect(link(7) == nil)                          // an unknown kind links nowhere

        // A spiking category the app can't name: the Insights categories, as the web without a code.
        #expect(rows[1].link(categories: [], today: today) == .categories)
        let backlog = Insight(insightCode: "ins_x", kind: "review_backlog", severity: "info", title: "", body: "")
        let pace = Insight(insightCode: "ins_y", kind: "spend_pace", severity: "warn", title: "", body: "")
        #expect(backlog.link(categories: []) == .review)
        #expect(pace.link(categories: []) == .trends)
    }

    @Test("link labels are the web's")
    func labels() throws {
        let rows = try insights()
        let labels = rows.map { $0.link(categories: categories, today: day("2026-10-14"))?.label }
        #expect(labels == ["See transaction", "See the category", "See statements", "See budgets", "Categorise them",
                           "See subscriptions", "See activity", nil])
        #expect(InsightLink.review.label == "Open review")
        #expect(InsightLink.trends.label == "See trends" && InsightLink.trends.opensInsights)
        #expect(InsightLink.subscriptions.opensInsights && !InsightLink.budgets.opensInsights)
    }

    @Test("sections in the web's order, alerts first then newest; an unknown kind under Other, last")
    func grouping() throws {
        let groups = InsightFeed.group(try insights())
        #expect(groups.map(\.label) == ["Spending", "Budgets", "Subscriptions", "Statements", "To tidy up", "Other"])
        // Spending: the alert (category spike) first, then the warnings newest first.
        #expect(groups[0].items.map(\.insightCode) == ["ins_01hzy3k8w9m2n4p6q8r0s2t4a2", "ins_01hzy3k8w9m2n4p6q8r0s2t4a1",
                                                      "ins_01hzy3k8w9m2n4p6q8r0s2t4a7"])
        #expect(groups[0].countLabel == "3 to look at")
        #expect(InsightFeed.group([]).isEmpty)
    }

    @Test("severity words and when it was noticed (Dubai days)")
    func wording() throws {
        let rows = try insights()
        #expect(rows[1].severityLabel == "Alert" && rows[0].severityLabel == "Heads-up" && rows[4].severityLabel == "Info")
        #expect(rows[0].noticedLabel(today: day("2026-10-14")) == "Noticed today")
        #expect(rows[1].noticedLabel(today: day("2026-10-14")) == "Noticed yesterday")
        #expect(rows[3].noticedLabel(today: day("2026-10-14")) == "Noticed 11 Oct")
    }

    @Test("following a link changes tab; Review opens on Overview")
    @MainActor
    func follow() {
        let router = TabRouter()
        router.follow(.budgets)
        #expect(router.tab == .budgets)
        router.follow(.statements)
        #expect(router.tab == .settings && router.settingsPath == [.statements])
        router.follow(.subscriptions)
        #expect(router.tab == .insights)
        router.follow(.review)
        #expect(router.tab == .overview && router.showingReview)
        router.follow(.transaction(txnCode: "txn_1"))
        #expect(router.tab == .activity && router.takeActivityTransaction() == "txn_1")
        var query = ActivityQuery()
        query.uncategorizedOnly = true
        router.follow(.activity(query))
        #expect(router.takeActivityPreset() == query)
    }
}

@Suite("Worth a look model: load, dismiss, ledger switch")
@MainActor
struct InsightFeedModelTests {
    @Test("loads every open insight; an owner's dismissal leaves at once and tells Overview")
    func dismiss() async throws {
        let api = StubAPI()
        api.insightRows = try insights()
        var changed: [String] = []
        let model = InsightFeedModel(api: api, categories: { categories })
        model.onChange = { changed.append($0) }
        #expect(model.summary == "What the nightly check noticed")
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(model.state.value?.count == 8)
        #expect(model.summary == "8 to look at")
        #expect(model.limitNote == nil)
        let first = try #require(model.groups?.first?.items.first)
        #expect(model.link(for: first, today: day("2026-10-14"))?.label == "See the category")

        await model.dismiss(first, profileCode: "prf_a")
        #expect(api.dismissedInsights == [first.insightCode])
        #expect(model.state.value?.contains(first) == false)
        #expect(changed == ["prf_a"])
    }

    @Test("the limit note shows once the read is full")
    func limit() async {
        let api = StubAPI()
        api.insightRows = (0..<InsightFeed.limit).map {
            Insight(insightCode: "ins_\($0)", kind: "spend_pace", severity: "info", title: "", body: "")
        }
        let model = InsightFeedModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(model.limitNote == "Showing the newest 100 insights.")
    }

    @Test("a failed read shows the error; another ledger clears the feed and Unusual spending")
    func ledgerSwitch() async throws {
        let api = StubAPI()
        api.insightsError = .network("-1009")
        let s = LedgerScreens(api: api, live: LiveUpdates(api: api, debounce: .milliseconds(5)),
                              today: { day("2026-10-14") })
        await s.select("prf_a")
        await s.feed.loadIfNeeded(profileCode: "prf_a")
        #expect(s.feed.state.errorMessage != nil)
        api.insightsError = nil
        api.insightRows = try insights()
        await s.feed.load(profileCode: "prf_a")
        await s.anomalies.loadIfNeeded(profileCode: "prf_a", from: day("2026-10-01"), to: day("2026-10-14"))
        #expect(s.feed.hasLoaded && s.anomalies.state.value != nil)

        await s.select("prf_b")
        #expect(!s.feed.hasLoaded && s.feed.state.value == nil)
        #expect(s.anomalies.state.value == nil)
        s.stop()
    }
}

@Suite("Unusual spending (PAR-9): anomalies in plain words, 'This is fine'")
struct AnomalyTests {
    private func rows() throws -> [Anomaly] { try LedgerJSON.decode([Anomaly].self, from: try fixture("anomalies")) }

    @Test("the anomalies row decodes with the server's figures as decimals")
    func decoding() throws {
        let rows = try rows()
        #expect(rows.count == 3)
        #expect(rows[0].amount == Decimal(string: "1250.00"))
        #expect(rows[0].baselineMean == 250)
        #expect(rows[1].timesUsual == Decimal(string: "2.3"))
        #expect(rows[0].txnDate == day("2026-10-03"))
        #expect(rows[2].baselineMean == nil && rows[2].timesUsual == nil)
    }

    @Test("name, reason chip and one plain sentence, as the web's anomalyExplanation")
    func wording() throws {
        let rows = try rows()
        #expect(rows.map(\.name) == ["Bayleaf Restaurant", "New Airline", "FIRST SHOP LLC"])
        #expect(rows.map(\.reasonLabel) == ["Higher than usual", "New merchant", "New merchant"])
        #expect(rows[0].explanation == "About 5× what you usually spend here (AED 250.00)")
        #expect(rows[1].explanation == "First purchase here, about 2.3× your usual Travel purchase (AED 3,000.00)")
        #expect(rows[2].explanation == "First purchase here")

        let category = Anomaly(txnCode: "txn_c", txnDate: day("2026-10-01"), description: "X", amount: 3000,
                               reason: "category_outlier", baselineMean: 300, baselineScope: "category", timesUsual: 10)
        #expect(category.explanation == "About 10× your usual purchase in this category (AED 300.00)")
        let noScope = Anomaly(txnCode: "txn_d", txnDate: day("2026-10-01"), description: "X", amount: 900,
                              reason: "merchant_outlier", baselineMean: 200)
        #expect(noScope.explanation == "Usually AED 200.00")
        let bare = Anomaly(txnCode: "txn_e", txnDate: day("2026-10-01"), description: "X", amount: 900, reason: nil)
        #expect(bare.explanation == "Higher than usual" && bare.reasonLabel == "Unusual")
    }

    @Test("titles and the copy the screen shows")
    func copy() {
        #expect(AnomaliesModel.title(count: 0) == "Unusual spending")
        #expect(AnomaliesModel.title(count: 1) == "Unusual spending · 1 charge")
        #expect(AnomaliesModel.title(count: 3) == "Unusual spending · 3 charges")
        #expect(AnomaliesModel.footnote.contains("12 months"))
    }

    @Test("'This is fine' sends dismiss_anomaly, drops the row, says so and tells the other screens")
    @MainActor
    func markFine() async throws {
        let api = StubAPI()
        api.anomalyRows = try rows()
        let model = AnomaliesModel(api: api)
        var changed: [String] = []
        model.onChange = { changed.append($0) }
        await model.loadIfNeeded(profileCode: "prf_a", from: day("2026-09-01"), to: day("2026-10-14"))
        #expect(api.anomalyRequests.map(\.from) == [day("2026-09-01")])
        let first = try #require(model.state.value?.first)

        await model.markFine(first, profileCode: "prf_a")
        #expect(api.dismissedAnomalies == [first.txnCode])
        #expect(model.state.value?.map(\.txnCode).contains(first.txnCode) == false)
        #expect(model.message == "Marked as fine. Bayleaf Restaurant won't be flagged again.")
        #expect(changed == ["prf_a"])
        #expect(model.working == nil)
    }

    @Test("a refused 'This is fine' keeps the row and says why")
    @MainActor
    func markFineFails() async throws {
        let api = StubAPI()
        api.anomalyRows = try rows()
        let model = AnomaliesModel(api: api)
        await model.load(profileCode: "prf_a", from: day("2026-09-01"), to: day("2026-10-14"))
        api.anomalyError = .server(status: 403, code: "42501", message: "permission denied")
        let first = try #require(model.state.value?.first)
        await model.markFine(first, profileCode: "prf_a")
        #expect(model.message?.hasPrefix("Couldn't mark it as fine") == true)
        #expect(api.dismissedAnomalies.isEmpty)
    }
}
