import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

private func rows(_ json: String) throws -> [CategorySpend] {
    try LedgerJSON.decode([CategorySpend].self, from: Data(json.utf8))
}

private func breakdown(_ json: String) throws -> SpendBreakdown {
    try SpendBreakdown.decode(Data(json.utf8))
}

private let dining = "cat_01hzy3k8w9m2n4p6q8r0s2t4d1"

private let categoryJSON = """
[{"category_code": "\(dining)", "name": "Dining", "color_token": "cat-4", "amount": "1200.50", "txn_count": 9,
  "share": "0.42", "prev_amount": "1000.00", "change": "0.2005"},
 {"category_code": null, "name": "Uncategorised", "color_token": null, "amount": "80.00", "txn_count": 1,
  "share": "0.028", "prev_amount": "0", "change": null}]
"""

private let trendJSON = """
{"group_by": "category", "total": "2400.00", "months": ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"],
 "groups": [{"key": "\(dining)", "label": "Dining", "color_token": "cat-4", "logo_path": null, "total": "2400.00", "share": "1"}],
 "series": [
  {"month": "2026-05", "total": "300.00", "values": {"\(dining)": "300.00"}},
  {"month": "2026-06", "total": "0", "values": {"\(dining)": "0"}},
  {"month": "2026-07", "total": "400.00", "values": {"\(dining)": "400.00"}},
  {"month": "2026-08", "total": "200.00", "values": {"\(dining)": "200.00"}},
  {"month": "2026-09", "total": "300.00", "values": {"\(dining)": "300.00"}},
  {"month": "2026-10", "total": "1200.00", "values": {"\(dining)": "1200.00"}}]}
"""

private let merchantsJSON = """
{"group_by": "merchant", "total": "1200.50", "months": ["2026-10"],
 "groups": [
  {"key": "mer_01hzy3k8w9m2n4p6q8r0s2t4m1", "label": "Careem Food", "color_token": null, "logo_path": null, "total": "600.00", "share": "0.4998"},
  {"key": "mer_01hzy3k8w9m2n4p6q8r0s2t4m2", "label": "Talabat", "color_token": null, "logo_path": null, "total": "300.00", "share": "0.2499"},
  {"key": "__other__", "label": "Others", "color_token": null, "logo_path": null, "total": "300.50", "share": "0.2503"}],
 "series": [{"month": "2026-10", "total": "1200.50", "values": {}}]}
"""

private let emptyJSON = """
{"group_by": "merchant", "total": "0", "months": ["2026-10"], "groups": [], "series": [{"month": "2026-10", "total": "0", "values": {}}]}
"""

@Suite("Category drill-down (PAR-5): requests, ranges and the server's figures in words")
struct CategoryDrillDownTests {
    let target = CategoryTarget(categoryCode: dining, name: "Dining", colorToken: "cat-4")

    @Test("the trend widens a short range to six whole months; a longer one is kept")
    func trendRange() {
        let month = CategoryDrillDownRequest(target: target, from: day("2026-10-01"), to: day("2026-10-13"))
        #expect(month.trendFrom == day("2026-05-01"))
        let year = CategoryDrillDownRequest(target: target, from: day("2025-11-01"), to: day("2026-10-13"))
        #expect(year.trendFrom == day("2025-11-01"))
    }

    @Test("the filter is the category's code; uncategorised is the spend RPCs' key")
    func filter() {
        #expect(target.filterKey == dining)
        let none = CategoryTarget(categoryCode: nil, name: "Uncategorised", colorToken: nil)
        #expect(none.filterKey == "__uncategorized__")
        let request = CategoryDrillDownRequest(target: none, from: day("2026-10-01"), to: day("2026-10-31"))
        #expect(request.filter.categoryCodes == ["__uncategorized__"])
    }

    @Test("range labels: this year without years, another year once, across years twice")
    func rangeLabels() {
        let today = day("2026-10-13")
        #expect(LedgerDates.rangeLabel(from: day("2026-05-01"), to: day("2026-10-13"), today: today) == "1 May – 13 Oct")
        #expect(LedgerDates.rangeLabel(from: day("2025-05-01"), to: day("2025-10-31"), today: today) == "1 May – 31 Oct 2025")
        #expect(LedgerDates.rangeLabel(from: day("2025-11-01"), to: day("2026-10-13"), today: today)
                == "1 Nov 2025 – 13 Oct 2026")
    }

    @Test("change vs the previous period: server fraction worded, more spend warns, null is New")
    func changeChip() throws {
        let r = try rows(categoryJSON)
        #expect(r[0].changeChip.label == "+20%" && r[0].changeChip.tone == .warn)
        #expect(r[0].previousLabel == "was AED 1,000")
        #expect(r[0].transactionsLabel == "9 transactions" && r[1].transactionsLabel == "1 transaction")
        #expect(r[0].shareLabel == "42%")
        #expect(r[1].changeChip.label == "New" && r[1].changeChip.tone == .neutral)
        #expect(r[1].previousLabel == "nothing the period before")
        let down = try rows("""
        [{"category_code": "c", "name": "n", "color_token": null, "amount": "1", "txn_count": 1, "share": "1",
          "prev_amount": "2", "change": "-0.5"},
         {"category_code": "d", "name": "n", "color_token": null, "amount": "1", "txn_count": 1, "share": "1",
          "prev_amount": "1", "change": "0.004"}]
        """)
        #expect(down[0].changeChip.label == "−50%" && down[0].changeChip.tone == .positive)
        #expect(down[1].changeChip.label == "±0%" && down[1].changeChip.tone == .neutral)
    }

    @Test("a server without `change` decodes it as nil")
    func changeAbsent() throws {
        let r = try rows("""
        [{"category_code": "c", "name": "n", "color_token": null, "amount": "1", "txn_count": 1, "share": "1", "prev_amount": "0"}]
        """)
        #expect(r[0].change == nil)
    }

    @Test("bars are the server's monthly totals, zero months included; the readout defaults to the latest")
    func bars() throws {
        let request = CategoryDrillDownRequest(target: target, from: day("2026-10-01"), to: day("2026-10-13"))
        let d = CategoryDrillDown(request: request, row: nil, trend: try breakdown(trendJSON),
                                  merchants: try breakdown(merchantsJSON))
        #expect(d.bars.map(\.label) == ["May", "Jun", "Jul", "Aug", "Sep", "Oct"])
        #expect(d.bars[1].amount == 0)
        #expect(d.bar(forLabel: nil)?.title == "October 2026")
        #expect(d.bar(forLabel: nil)?.amountLabel == "AED 1,200")
        #expect(d.bar(forLabel: "Jul")?.amount == 400)
        let none = CategoryDrillDown(request: request, row: nil, trend: try breakdown(emptyJSON),
                                     merchants: try breakdown(emptyJSON))
        #expect(none.bars.isEmpty && none.merchantRows.isEmpty)
    }

    @Test("merchant rows: amounts and shares as sent, bars against the top merchant, Others muted")
    func merchants() throws {
        let request = CategoryDrillDownRequest(target: target, from: day("2026-10-01"), to: day("2026-10-13"))
        let d = CategoryDrillDown(request: request, row: nil, trend: try breakdown(trendJSON),
                                  merchants: try breakdown(merchantsJSON))
        let m = d.merchantRows
        #expect(m.map(\.label) == ["Careem Food", "Talabat", "Others"])
        #expect(m[0].amountLabel == "AED 600" && m[0].shareLabel == "50%")
        #expect(m[0].barFraction == 1)
        #expect(abs(m[1].barFraction - 0.5) < 0.001)
        #expect(!m[0].isBucket && m[2].isBucket)
    }

    @Test("the model loads the row, the six-month trend and the top 8 merchants, all filtered to the category")
    @MainActor
    func modelLoads() async throws {
        let api = StubAPI()
        api.categoryRows = try rows(categoryJSON)
        api.breakdownByGroup = [.category: try breakdown(trendJSON), .merchant: try breakdown(merchantsJSON)]
        let model = CategoryDrillDownModel(api: api)
        let request = CategoryDrillDownRequest(target: target, from: day("2026-10-01"), to: day("2026-10-13"))
        await model.load(profileCode: "prf_x", request: request)
        let d = try #require(model.state.value)
        #expect(d.row?.amount == Decimal(string: "1200.5"))
        #expect(api.breakdownFilters.allSatisfy { $0.categoryCodes == [dining] })
        let trend = try #require(api.breakdownRequests.first { $0.groupBy == .category })
        #expect(trend.from == day("2026-05-01") && trend.to == day("2026-10-13") && trend.topN == 1)
        let merchants = try #require(api.breakdownRequests.first { $0.groupBy == .merchant })
        #expect(merchants.from == day("2026-10-01") && merchants.topN == 8)
        #expect(model.readout?.title == "October 2026")
        model.selectedMonth = "Jul"
        #expect(model.readout?.amount == 400)

        // Uncategorised finds the null-code row; a category without spend in the range has none.
        let none = CategoryDrillDownModel(api: api)
        await none.load(profileCode: "prf_x", request: CategoryDrillDownRequest(
            target: CategoryTarget(categoryCode: nil, name: "Uncategorised", colorToken: nil),
            from: day("2026-10-01"), to: day("2026-10-13")))
        #expect(none.state.value?.row?.amount == 80)
        let missing = CategoryDrillDownModel(api: api)
        await missing.load(profileCode: "prf_x", request: CategoryDrillDownRequest(
            target: CategoryTarget(categoryCode: "cat_other", name: "Travel", colorToken: nil),
            from: day("2026-10-01"), to: day("2026-10-13")))
        #expect(missing.state.value != nil && missing.state.value?.row == nil)
    }

    @Test("a failed load shows the error, not an empty category")
    @MainActor
    func modelFails() async {
        let api = StubAPI()   // no breakdown: spend_breakdown throws
        let model = CategoryDrillDownModel(api: api)
        await model.load(profileCode: "prf_x", request: CategoryDrillDownRequest(
            target: target, from: day("2026-10-01"), to: day("2026-10-13")))
        #expect(model.state.value == nil && model.state.errorMessage != nil)
    }

    @Test("the Overview ring opens the month on screen, and a slice is found by its angle value")
    func overviewRing() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let first = try #require(o.ringCategories.first)
        let request = o.drillDown(first)
        #expect(request.from == day("2026-10-01") && request.to == day("2026-10-31"))
        #expect(request.target.categoryCode == first.categoryCode && request.target.name == first.displayName)
        let cats = o.ringCategories
        #expect(Overview.ringCategory(cats, atAngleValue: 0.5)?.id == cats[0].id)
        let pastFirst = cats[0].amount.chartValue + 0.01
        #expect(Overview.ringCategory(cats, atAngleValue: pastFirst)?.id == cats[safeIndex: 1]?.id)
        #expect(Overview.ringCategory([], atAngleValue: 1) == nil)
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
