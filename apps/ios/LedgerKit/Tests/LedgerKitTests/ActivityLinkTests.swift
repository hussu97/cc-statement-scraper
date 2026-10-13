import Foundation
import Testing
@testable import LedgerKit

@MainActor
@Suite("Opening Activity from other screens (PAR-4)")
struct ActivityLinkTests {
    func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

    @Test("openActivity switches to Activity with the query, once; each call bumps the request")
    func openActivity() {
        let router = TabRouter()
        var query = ActivityQuery()
        query.status = .void
        router.openActivity(query)
        #expect(router.tab == .activity && router.activityPresetRequest == 1)
        #expect(router.takeActivityPreset() == query && router.takeActivityPreset() == nil)
        #expect(router.takeActivityTransaction() == nil)
        router.openActivity(query)
        #expect(router.activityPresetRequest == 2)
    }

    @Test("openTransaction opens one transaction over Activity's own filters; the latest request wins")
    func openTransaction() {
        let router = TabRouter()
        let preset = ActivityQuery.uncategorised(month: day("2026-10-01"))
        router.openActivity(preset)
        router.openTransaction("txn_1")
        #expect(router.tab == .activity && router.activityPresetRequest == 2)
        #expect(router.takeActivityPreset() == nil)
        #expect(router.takeActivityTransaction() == "txn_1" && router.takeActivityTransaction() == nil)
        router.openTransaction("txn_2")
        router.openActivity(preset)
        #expect(router.takeActivityTransaction() == nil && router.takeActivityPreset() == preset)
        router.openTransaction("txn_3")
        router.reset()
        #expect(router.takeActivityTransaction() == nil && router.tab == .overview)
    }

    @Test("ledger://uncategorised goes through openActivity")
    func uncategorisedLink() {
        let router = TabRouter(today: { CalendarDay(year: 2026, month: 10, day: 13) })
        router.open(.uncategorised, ledgerOnScreen: true)
        #expect(router.activityPresetRequest == 1)
        #expect(router.takeActivityPreset() == .uncategorised(month: day("2026-10-01")))
    }

    @Test("Overview's link: the month's uncategorised rows")
    func overviewLinks() throws {
        let overview = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let uncategorised = overview.uncategorisedActivity
        #expect(uncategorised.uncategorizedOnly && uncategorised.month == overview.month.startOfMonth)
        #expect(uncategorised.activityFilter["category"] == "none")
    }

    @Test("a merchant row: its name as the search, the range shown; never the unknown bucket")
    func merchantLink() throws {
        func merchant(_ code: String?, _ name: String) throws -> MerchantSpend {
            let json = """
            {"merchant_code": \(code.map { "\"\($0)\"" } ?? "null"), "merchant_name": "\(name)", "category_code": null,
             "category_name": null, "amount": 120.5, "txn_count": 3, "avg_amount": 40.17, "last_date": "2026-10-01"}
            """
            return try LedgerJSON.decode(MerchantSpend.self, from: Data(json.utf8))
        }
        let query = try #require(try merchant("mer_1", "  Carrefour ").activityQuery(from: day("2026-05-01"), to: day("2026-10-13")))
        #expect(query.search == "Carrefour" && query.from == day("2026-05-01") && query.to == day("2026-10-13"))
        #expect(query.activityFilter == ["q": "Carrefour", "from": "2026-05-01", "to": "2026-10-13"])
        #expect(try merchant(nil, "Unknown merchant").activityQuery(from: day("2026-05-01"), to: day("2026-10-13")) == nil)
        #expect(ActivityQuery.merchant("   ", from: day("2026-05-01"), to: day("2026-10-13")) == nil)
        #expect(ActivityQuery.merchant(String(repeating: "x", count: 200), from: day("2026-05-01"), to: day("2026-10-13"))?
            .search.count == 120)
    }

    @Test("Activity shows exactly the query it was opened with, search included")
    func showReplacesSearch() async {
        let api = StubAPI()
        let model = ActivityModel(api: api)
        model.query.search = "typed earlier"
        model.query.cardCode = "crd_1"
        let query = try! #require(ActivityQuery.merchant("Noon", from: day("2026-09-01"), to: day("2026-09-30")))
        await model.show(query, profileCode: "prf_a")
        #expect(model.query == query && model.query.cardCode == nil)
        #expect(api.transactionRequests.last?.query == query)
    }

    @Test("a transaction opened from Overview is read from the ledger; a missing one says so")
    func transactionByCode() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = [txn("txn_1")]
        let model = ActivityModel(api: api)
        #expect(await model.transaction("txn_1", profileCode: "prf_a")?.txnCode == "txn_1")
        #expect(model.errorMessage == nil)
        #expect(await model.transaction("txn_gone", profileCode: "prf_a") == nil)
        #expect(model.errorMessage == "This transaction is no longer in this ledger.")
    }
}
