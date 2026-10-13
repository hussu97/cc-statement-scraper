import Foundation
import Testing
@testable import LedgerKit

/// A `v_transactions` row with what the paging and recategorise tests vary.
func txn(_ code: String, profile: String = "prf_a", day: String = "2026-10-01", merchant: String? = nil,
         category: String? = nil) -> LedgerTransaction {
    let json: [String: Any?] = [
        "txn_code": code, "profile_code": profile, "account_code": "acc_1", "card_code": nil,
        "status": "posted", "kind": "purchase", "direction": "debit", "txn_date": day, "txn_at": nil,
        "posting_date": nil, "stmt_code": nil, "merchant_code": merchant, "description": "SHOP \(code)",
        "merchant_name": merchant, "amount_original": "10.00", "currency_original": "AED", "amount_aed": "10.00",
        "amount_aed_is_estimate": false, "fx_rate": nil, "auth_amount": nil, "amount_source": "sms",
        "related_txn_code": nil, "exclude_from_spend": false, "notes": nil, "category_code": category,
        "category_name": category.map { "Name \($0)" }, "category_color": nil, "category_kind": nil,
        "category_source": category == nil ? nil : "manual", "bank_code": "FAB", "card_last4": "1234",
        "account_nickname": nil, "has_sms": true, "has_statement": false,
    ]
    let data = try! JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() })
    return try! LedgerJSON.decode(LedgerTransaction.self, from: data)
}

func txns(_ range: Range<Int>, profile: String = "prf_a", merchantEvery: Int? = nil) -> [LedgerTransaction] {
    range.map { i in
        txn("txn_\(profile)_\(i)", profile: profile,
            merchant: merchantEvery.flatMap { i % $0 == 0 ? "mer_x" : nil })
    }
}

@MainActor
@Suite("Activity: filters, paging, recategorise in place (IOS-15)")
struct ActivityModelTests {
    @Test("Activity pages through v_transactions 100 rows at a time")
    func paging() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = txns(0..<230)
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(model.rows.count == 100 && model.footer == .more)
        await model.rowAppeared(model.rows[95])
        await model.loadMore()
        #expect(model.rows.count == 230 && model.footer == .end)
        #expect(api.transactionRequests.map(\.page.offset) == [0, 100, 200])
        #expect(api.transactionRequests.allSatisfy { $0.page.limit == 100 })
        #expect(model.endMessage == "All 230 transactions")
    }

    @Test("the filter sheet edits a copy: nothing changes until Apply, and Apply keeps the search")
    func filtersApplyCopy() async {
        let api = StubAPI()
        let model = ActivityModel(api: api)
        model.query.search = "noon"
        var draft = model.query
        draft.status = .void
        draft.month = CalendarDay(iso: "2026-09-14")
        #expect(model.query.status == .all && !model.query.hasFilters)   // swiped away: unchanged
        draft.search = "stale"
        await model.apply(draft, profileCode: "prf_a")
        #expect(model.query.status == .void && model.query.search == "noon")
        #expect(model.query.from == CalendarDay(iso: "2026-09-01") && model.query.to == CalendarDay(iso: "2026-09-30"))
        #expect(api.transactionRequests.last?.query == model.query)
    }

    @Test("a month filter reads back only for a whole month")
    func monthFilter() {
        var q = ActivityQuery()
        q.month = CalendarDay(iso: "2028-02-10")
        #expect(q.from == CalendarDay(iso: "2028-02-01") && q.to == CalendarDay(iso: "2028-02-29"))
        #expect(q.month == CalendarDay(iso: "2028-02-01"))
        q.to = CalendarDay(iso: "2028-02-28")
        #expect(q.month == nil)
        q.month = nil
        #expect(q.from == nil && q.to == nil && !q.hasFilters)
    }

    @Test("recategorising patches the row in place: no reset to page 1, scrolled pages kept")
    func recategoriseInPlace() async throws {
        let api = StubAPI()
        api.transactionRows["prf_a"] = txns(0..<250)
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        await model.loadMore()
        let target = model.rows[150]
        let before = api.calls("transactions")
        api.transactionRows["prf_a"]![150] = txn(target.txnCode, category: "cat_food")
        try await model.saveCategory(target, to: "cat_food", applyToMerchant: false, profileCode: "prf_a")
        #expect(api.calls("transactions") == before)          // no page reloaded
        #expect(model.rows.count == 200)
        #expect(model.rows[150].txnCode == target.txnCode && model.rows[150].categoryCode == "cat_food")
        #expect(api.recategorised.last?.merchant == false)
    }

    @Test("under 'Uncategorised only', a categorised row leaves the list and paging stays aligned")
    func recategoriseLeavesFilter() async throws {
        let api = StubAPI()
        api.transactionRows["prf_a"] = txns(0..<150)
        let model = ActivityModel(api: api)
        var draft = model.query
        draft.uncategorizedOnly = true
        await model.apply(draft, profileCode: "prf_a")
        let target = model.rows[10]
        api.transactionRows["prf_a"]![10] = txn(target.txnCode, category: "cat_food")
        try await model.saveCategory(target, to: "cat_food", applyToMerchant: false, profileCode: "prf_a")
        #expect(!model.rows.contains { $0.txnCode == target.txnCode })
        await model.loadMore()
        #expect(api.transactionRequests.last?.page.offset == 99)
        #expect(model.rows.count == 149 && Set(model.rows.map(\.txnCode)).count == 149)
    }

    @Test("for the whole merchant, every loaded row of that merchant is re-read")
    func merchantRows() {
        let rows = txns(0..<10, merchantEvery: 3)       // 0, 3, 6, 9 are mer_x
        let codes = ActivityModel.affectedCodes(of: rows[3], wholeMerchant: true, in: rows)
        #expect(codes == ["txn_prf_a_3", "txn_prf_a_0", "txn_prf_a_6", "txn_prf_a_9"])
        #expect(ActivityModel.affectedCodes(of: rows[3], wholeMerchant: false, in: rows) == ["txn_prf_a_3"])
        #expect(ActivityModel.affectedCodes(of: rows[1], wholeMerchant: true, in: rows) == ["txn_prf_a_1"])
    }

    @Test("typing a search keeps the rows on screen; a new filter or ledger does not")
    func keepsRows() {
        var a = ActivityQuery()
        var b = a
        b.search = "carrefour"
        #expect(ActivityModel.keepsRows(from: ("prf_a", a), to: ("prf_a", b)))
        #expect(!ActivityModel.keepsRows(from: ("prf_a", a), to: ("prf_b", a)))
        a.status = .void
        #expect(!ActivityModel.keepsRows(from: ("prf_a", a), to: ("prf_a", b)))
    }

    @Test("day sections are built once per change of the rows or the day, not per redraw (IOS-26)")
    func sectionsCached() async throws {
        let api = StubAPI()
        api.transactionRows["prf_a"] = (0..<150).map { i in txn("txn_\(i)", day: i < 60 ? "2026-10-08" : "2026-10-07") }
        let model = ActivityModel(api: api)
        let today = try #require(CalendarDay(iso: "2026-10-08"))
        #expect(model.sections(today: today).isEmpty)
        await model.load(profileCode: "prf_a")
        let first = model.sections(today: today)
        let builds = model.sectionBuilds
        // Redraws with nothing changed reuse the sections.
        for _ in 0..<5 { #expect(model.sections(today: today) == first) }
        #expect(model.sectionBuilds == builds)
        #expect(first.map(\.title) == ["Today", "Yesterday"] && first.map(\.rows.count) == [60, 40])

        // A new page rebuilds them.
        await model.loadMore()
        #expect(model.sections(today: today).map(\.rows.count) == [60, 90])
        #expect(model.sectionBuilds == builds + 1)

        // A patched row shows (a recategorise re-reads it in place).
        api.transactionRows["prf_a"]![0] = txn("txn_0", day: "2026-10-08", category: "cat_food")
        try await model.saveCategory(model.rows[0], to: "cat_food", applyToMerchant: false, profileCode: "prf_a")
        #expect(model.sections(today: today).first?.rows.first?.categoryCode == "cat_food")

        // The day rolling over relabels them without a reload.
        #expect(model.sections(today: today.adding(days: 1)).map(\.title) == ["Yesterday", "7 Oct"])

        // Another ledger: nothing of the old rows.
        model.reset()
        #expect(model.sections(today: today).isEmpty)
    }
}

@MainActor
final class Seen {
    var tables: [Set<String>] = []
}

@MainActor
@Suite("Ledger screens: switching ledger, months, refresh (IOS-13, IOS-14)")
struct LedgerScreensTests {
    func screens(_ api: StubAPI) -> LedgerScreens {
        LedgerScreens(api: api, live: LiveUpdates(api: api, debounce: .milliseconds(5)),
                      today: { CalendarDay(iso: "2026-10-08")! })
    }

    @Test("switching ledger clears every tab before the new ledger loads")
    func switchClears() async throws {
        let api = StubAPI()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        api.transactionRows = ["prf_a": txns(0..<5), "prf_b": txns(0..<3, profile: "prf_b")]
        api.documentRows = []
        let s = screens(api)
        await s.select("prf_a")
        await s.insights.loadIfNeeded(profileCode: "prf_a", month: nil)
        await s.statements.loadIfNeeded(profileCode: "prf_a")
        s.month.select(CalendarDay(iso: "2026-07-01")!)
        #expect(s.insights.state.value != nil && s.statements.hasLoaded)

        await s.select("prf_b")
        #expect(s.activeProfile == "prf_b")
        #expect(s.activity.rows.map(\.profileCode) == ["prf_b", "prf_b", "prf_b"])
        #expect(s.insights.state.value == nil && !s.insights.hasLoaded)   // not opened for prf_b yet
        #expect(!s.statements.hasLoaded)
        #expect(s.month.isCurrent)                                         // back to this month
        #expect(api.overviewMonths.last == .some(nil))
        s.stop()
    }

    @Test("the month's first day comes from filter_meta; Overview asks for the month on screen")
    func monthBounds() async throws {
        let api = StubAPI()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        api.firstTransactionDay = CalendarDay(iso: "2026-06-12")
        let s = screens(api)
        await s.select("prf_a")
        #expect(s.month.range.earliest == CalendarDay(iso: "2026-06-01"))
        s.month.goBack()
        await s.overview.loadIfNeeded(profileCode: "prf_a", month: s.month.requestMonth)
        await s.overview.loadIfNeeded(profileCode: "prf_a", month: s.month.requestMonth)   // already on screen
        #expect(api.overviewMonths == [nil, CalendarDay(iso: "2026-09-01")])
        await s.insights.loadIfNeeded(profileCode: "prf_a", month: s.month.requestMonth)
        #expect(api.budgetMonths == [CalendarDay(iso: "2026-09-01")])
        s.stop()
    }

    @Test("Realtime and the foreground refresh every opened tab, Insights included, and nothing unopened")
    func refreshFanOut() async throws {
        let api = StubAPI()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let s = screens(api)
        await s.select("prf_a")
        await s.refreshAll()
        #expect(api.calls("overview") == 2)
        #expect(api.calls("transactions") == 2)
        #expect(api.calls("categoryBreakdown") == 0)      // Insights never opened
        #expect(api.calls("documents") == 0 && api.calls("reviewInbox") == 0)

        await s.insights.loadIfNeeded(profileCode: "prf_a", month: nil)
        await s.statements.loadIfNeeded(profileCode: "prf_a")
        await s.review.open(profileCode: "prf_a")
        await s.refreshAll()
        #expect(api.calls("categoryBreakdown") == 2)
        #expect(api.calls("documents") == 2 && api.calls("reviewInbox") == 2)

        await s.refresh(after: ["documents"])
        #expect(api.calls("documents") == 3 && api.calls("overview") == 3)
        #expect(api.calls("categoryBreakdown") == 2)
        s.stop()
    }

    @Test("a dropped Realtime subscription is opened again, and the reconnect refreshes the tabs")
    func resubscribes() async throws {
        let api = StubAPI()
        api.changeScript = [[], ["transactions"]]       // fails at once, then delivers one change and drops
        let live = LiveUpdates(api: api, debounce: .milliseconds(1), backoff: Backoff(base: 0.01, cap: 0.02))
        let seen = Seen()
        live.start(profileCode: "prf_a") { seen.tables.append($0) }
        for _ in 0..<400 where api.subscriptions < 3 || seen.tables.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(api.subscriptions >= 3)                       // still following after two drops
        #expect(seen.tables.first == LiveUpdates.tables)      // reconnect: refresh everything
        #expect(seen.tables.contains(["transactions"]))
        live.stop()
        #expect(!live.isRunning)
    }
}
