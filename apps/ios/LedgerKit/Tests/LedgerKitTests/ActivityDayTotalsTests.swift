import Foundation
import Supabase
import Testing
@testable import LedgerKit

/// 230 rows, 10 a day, newest first: 28 Oct back to 6 Oct.
private func rowsByDay() -> [LedgerTransaction] {
    (0..<230).map { i in txn("txn_\(i)", day: CalendarDay(year: 2026, month: 10, day: 28 - i / 10).iso) }
}

private func day(_ d: Int) -> CalendarDay { CalendarDay(year: 2026, month: 10, day: d) }

@MainActor
@Suite("Activity date headers: per-day net totals (PAR-3)")
struct ActivityDayTotalsTests {
    @Test("one call per page, for that page's days only; the boundary day isn't asked twice")
    func onePerPage() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = rowsByDay()
        api.dayTotalRows[day(28)] = DayTotal(txnDate: day(28), txnCount: 10, netAed: 100)
        api.dayTotalRows[day(19)] = DayTotal(txnDate: day(19), txnCount: 10, netAed: Decimal(string: "-40.6")!, hasEstimate: true)
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(api.dayTotalCalls.count == 1)
        #expect(api.dayTotalCalls[0].days == (19...28).reversed().map(day))     // page 1: 28 Oct … 19 Oct
        #expect(model.dayTotal(for: day(28))?.label == "AED 100")
        #expect(model.dayTotal(for: day(27)) == nil)                          // not returned: no figure
        #expect(model.dayTotal(for: day(19))?.label == "≈ −AED 41")

        await model.loadMore()
        #expect(api.dayTotalCalls.count == 2)
        #expect(api.dayTotalCalls[1].days == (9...18).reversed().map(day))     // only the new days
        await model.footerAppeared()                                          // page 3: the last 30 rows
        #expect(api.dayTotalCalls.count == 3 && api.dayTotalCalls[2].days == [day(8), day(7), day(6)])
        await model.footerAppeared()                                          // the end: nothing new, no call
        #expect(api.dayTotalCalls.count == 3)
    }

    @Test("the filter goes as the web's activityFilter object; new filters start from nothing")
    func filterAndReset() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = rowsByDay()
        api.dayTotalRows[day(28)] = DayTotal(txnDate: day(28), txnCount: 10, netAed: 100)
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        var draft = model.query
        draft.status = .void
        draft.cardCode = "crd_1"
        api.dayTotalRows = [:]
        await model.apply(draft, profileCode: "prf_a")
        #expect(api.dayTotalCalls.last?.query.activityFilter == ["status": "void", "card": "crd_1", "scope": "spending"])
        #expect(model.dayTotal(for: day(28)) == nil)                          // the old filter's figure is gone

        let params = draft.dayTotalsParams(profileCode: "prf_a", days: [day(28), day(27)])
        #expect(params["p_filter"] == .object(["status": .string("void"), "card": .string("crd_1"), "scope": .string("spending")]))
        #expect(params["p_days"] == .array([.string("2026-10-28"), .string("2026-10-27")]))
        #expect(params["p_profile_code"] == .string("prf_a"))
    }

    @Test("a failed call leaves the headers bare and is asked again; refresh re-reads the head's days")
    func failureAndRefresh() async {
        let api = StubAPI()
        api.transactionRows["prf_a"] = rowsByDay()
        api.dayTotalsError = .network("-1009")
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(model.dayTotal(for: day(28)) == nil && model.rows.count == 100)
        api.dayTotalsError = nil
        api.dayTotalRows[day(28)] = DayTotal(txnDate: day(28), txnCount: 10, netAed: 100)
        await model.loadMore()
        #expect(api.dayTotalCalls.last?.days.first == day(28))                // the failed days again, with the new page
        #expect(model.dayTotal(for: day(28))?.label == "AED 100")

        api.dayTotalRows[day(28)] = DayTotal(txnDate: day(28), txnCount: 11, netAed: 120)
        await model.refresh(profileCode: "prf_a")
        #expect(api.dayTotalCalls.last?.days == (19...28).reversed().map(day))
        #expect(model.dayTotal(for: day(28))?.txnCount == 11)
        model.reset()
        #expect(model.dayTotal(for: day(28)) == nil)
    }

    @Test("an edit re-reads its day's total")
    func editRereadsDay() async throws {
        let api = StubAPI()
        api.transactionRows["prf_a"] = rowsByDay()
        let model = ActivityModel(api: api)
        await model.load(profileCode: "prf_a")
        try await model.saveEdit(model.rows[25], .excludeFromSpend(true), profileCode: "prf_a")
        #expect(api.dayTotalCalls.last?.days == [day(26)])
    }

    @Test("days: distinct, in order, minus those asked for, at most 2000")
    func distinctDays() {
        let days = [day(3), day(3), day(2), day(1), day(2)]
        #expect(ActivityDayTotals.days(days, skipping: []) == [day(3), day(2), day(1)])
        #expect(ActivityDayTotals.days(days, skipping: [day(3)]) == [day(2), day(1)])
        let many = (0..<2500).map { CalendarDay(year: 2020, month: 1, day: 1).adding(days: $0) }
        #expect(ActivityDayTotals.days(many, skipping: []).count == 2000)
    }

    @Test("decodes the RPC rows: net as a decimal string")
    func decoding() throws {
        let json = #"[{"txn_date": "2026-10-08", "txn_count": 3, "net_aed": "1234.50", "unpriced_count": 1, "has_estimate": false}]"#
        let rows = try LedgerJSON.decode([DayTotal].self, from: Data(json.utf8))
        #expect(rows == [DayTotal(txnDate: day(8), txnCount: 3, netAed: Decimal(string: "1234.50")!, unpricedCount: 1)])
        #expect(rows[0].label == "AED 1,235")
        #expect(rows[0].accessibilityLabel == "Net of 3 transactions that day, AED 1,235")
    }
}
