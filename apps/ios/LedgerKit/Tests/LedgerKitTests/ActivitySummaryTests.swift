import Foundation
import Supabase
import Testing
@testable import LedgerKit

@Suite("Activity summary header: params, decoding, wording")
struct ActivitySummaryTests {
    @Test("no filters: every argument but the profile is null")
    func paramsDefault() {
        let p = ActivityQuery().summaryParams(profileCode: "prf_a")
        #expect(p == [
            "p_profile_code": .string("prf_a"), "p_from": .null, "p_to": .null, "p_account_code": .null,
            "p_card_code": .null, "p_category_code": .null, "p_uncategorized": .bool(false),
            "p_status": .null, "p_source": .null, "p_q": .null,
        ])
    }

    @Test("filters map one to one; the search goes raw (the server cleans it)")
    func paramsFilters() {
        var q = ActivityQuery()
        q.search = "  café, (dxb) 50%  "
        q.accountCode = "acc_1"
        q.categoryCode = "cat_food"
        q.status = .void
        q.month = CalendarDay(iso: "2026-09-14")
        let p = q.summaryParams(profileCode: "prf_a")
        #expect(p["p_q"] == .string("café, (dxb) 50%"))
        #expect(p["p_from"] == .string("2026-09-01") && p["p_to"] == .string("2026-09-30"))
        #expect(p["p_account_code"] == .string("acc_1") && p["p_category_code"] == .string("cat_food"))
        #expect(p["p_status"] == .string("void") && p["p_uncategorized"] == .bool(false))
        #expect(p["p_card_code"] == .null && p["p_source"] == .null)
    }

    @Test("'Uncategorised only' wins over a category, as in the list")
    func paramsUncategorized() {
        var q = ActivityQuery()
        q.categoryCode = "cat_food"
        q.uncategorizedOnly = true
        q.search = "   "
        let p = q.summaryParams(profileCode: "prf_a")
        #expect(p["p_uncategorized"] == .bool(true) && p["p_category_code"] == .null && p["p_q"] == .null)
    }

    @Test("decodes the jsonb: money from a string, dates as calendar days, null dates")
    func decoding() throws {
        let full = Data(#"{"txn_count": 42, "net_aed": "1234567.89", "unpriced_count": 2, "has_estimate": true, "earliest_date": "2026-06-01", "latest_date": "2026-10-08"}"#.utf8)
        let s = try LedgerJSON.decode(ActivitySummary.self, from: full)
        #expect(s.txnCount == 42 && s.netAed == Decimal(string: "1234567.89")! && s.unpricedCount == 2 && s.hasEstimate)
        #expect(s.earliestDate == CalendarDay(iso: "2026-06-01") && s.latestDate == CalendarDay(iso: "2026-10-08"))

        let empty = Data(#"{"txn_count": 0, "net_aed": "0.00", "unpriced_count": 0, "has_estimate": false, "earliest_date": null, "latest_date": null}"#.utf8)
        let e = try LedgerJSON.decode(ActivitySummary.self, from: empty)
        #expect(e.txnCount == 0 && e.netAed == 0 && e.earliestDate == nil && e.latestDate == nil)

        let bad = Data(#"{"txn_count": 1, "net_aed": "5O", "unpriced_count": 0, "has_estimate": false, "earliest_date": null, "latest_date": null}"#.utf8)
        #expect(throws: DecodingError.self) { try LedgerJSON.decode(ActivitySummary.self, from: bad) }
    }

    @Test("header wording: count, net, estimate, range, unpriced note")
    func header() {
        let day = { (iso: String) in CalendarDay(iso: iso)! }
        let h = ActivitySummaryHeader(ActivitySummary(
            txnCount: 1234, netAed: Decimal(string: "105.5")!, unpricedCount: 3, hasEstimate: false,
            earliestDate: day("2026-06-01"), latestDate: day("2026-10-08")))
        #expect(h.countText == "1,234 transactions")
        #expect(h.netText == "AED 105.50" && !h.isNetCredit)
        #expect(h.dateRangeText == "1 Jun 2026 – 8 Oct 2026")
        #expect(h.unpricedNote == "excl. 3 without AED amount")

        let one = ActivitySummaryHeader(ActivitySummary(
            txnCount: 1, netAed: Decimal(string: "-20")!, hasEstimate: true,
            earliestDate: day("2026-10-08"), latestDate: day("2026-10-08")))
        #expect(one.countText == "1 transaction")
        #expect(one.netText == "+ ≈ AED 20.00" && one.isNetCredit)
        #expect(one.dateRangeText == "8 Oct 2026" && one.unpricedNote == nil)

        let none = ActivitySummaryHeader(ActivitySummary(txnCount: 0, netAed: 0))
        #expect(none.countText == "0 transactions" && none.netText == "AED 0.00" && none.dateRangeText == nil)
    }

    @Test("display: placeholder while the first answer loads, hidden on failure")
    func display() {
        let s = ActivitySummary(txnCount: 2, netAed: 10)
        #expect(ActivitySummaryDisplay.of(.idle) == .hidden)
        #expect(ActivitySummaryDisplay.of(.loading(previous: nil)) == .placeholder)
        #expect(ActivitySummaryDisplay.of(.loading(previous: s)) == .shown(ActivitySummaryHeader(s)))
        #expect(ActivitySummaryDisplay.of(.loaded(s)) == .shown(ActivitySummaryHeader(s)))
        #expect(ActivitySummaryDisplay.of(.failed("x", previous: s)) == .hidden)
    }
}

@MainActor
@Suite("Activity summary in the model")
struct ActivitySummaryModelTests {
    @Test("loads with the first page, for the current filters, and again on new filters")
    func loadsWithList() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = txns(0..<3)
        api.summaryResult = .success(ActivitySummary(txnCount: 3, netAed: 30))
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(model.summaryDisplay == .shown(ActivitySummaryHeader(ActivitySummary(txnCount: 3, netAed: 30))))
        var draft = model.query
        draft.status = .void
        await model.apply(draft, profileCode: "prf_a")
        #expect(api.summaryQueries.count == 2 && api.summaryQueries.last?.status == .void)
        await model.refresh(profileCode: "prf_a")
        #expect(api.summaryQueries.count == 3)
    }

    @Test("a failed summary hides the header and leaves the list alone")
    func failureKeepsList() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = txns(0..<3)
        api.summaryResult = .failure(.network("offline"))
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(model.summaryDisplay == .hidden)
        #expect(model.rows.count == 3 && model.state.errorMessage == nil)
    }

    @Test("reset clears the header")
    func resetClears() async {
        let api = StubAPI()
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        model.reset()
        #expect(model.summaryDisplay == .hidden)
    }
}
