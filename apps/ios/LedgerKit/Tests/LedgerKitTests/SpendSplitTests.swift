import Foundation
import Testing
@testable import LedgerKit

@Suite("spend_breakdown: the Monthly spend split")
struct SpendSplitTests {
    @Test("group keys survive decoding (no snake-case rewrite), money exact, Others last")
    func decode() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_category"))
        #expect(b.groupBy == "category")
        #expect(b.groups.map(\.key) == ["cat_01hzy3k8w9m2n4p6q8r0s2t4c1", "__uncategorized__"])
        #expect(b.series[0].values["cat_01hzy3k8w9m2n4p6q8r0s2t4c1"] == Decimal(string: "600.40")!)
        #expect(b.groups[0].share == Decimal(string: "0.6978")!)
        #expect(MoneyFormat.plain(b.total) == "860.4")

        let bank = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        #expect(bank.groups.last?.isOther == true)
        #expect(bank.groups[0].logoPath == "FAB.png")
        #expect(bank.showsBankLogos)
    }

    @Test("colours: category tokens; banks and merchants take the palette in rank order; Others its own neutral")
    func colours() throws {
        let cat = try SpendBreakdown.decode(try fixture("spend_breakdown_category"))
        #expect(cat.groups.map(cat.colorToken(for:)) == ["cat-3", nil])
        let bank = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        #expect(bank.groups.map(bank.colorToken(for:)) == ["cat-1", "cat-2", "other"])
    }

    @Test("the rank palette is every categorical token, cat-1 … cat-16 (WEB-17r)")
    func rankPalette() {
        #expect(ChartPalette.categoryTokens == (1...16).map { "cat-\($0)" })
    }

    @Test("segments skip zero cells; every month stays on the axis")
    func segments() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        #expect(b.monthLabels == ["Aug", "Sep", "Oct"])
        #expect(b.segments.map(\.id) == ["2026-08|FAB", "2026-08|ADCB", "2026-10|FAB", "2026-10|ADCB", "2026-10|__other__"])
        #expect(b.segments[0].amount == Decimal(string: "750.00")!)
    }

    @Test("callout: the month's server total and each group's slice of it")
    func callout() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let oct = try #require(b.callout(forMonthLabel: "Oct"))
        #expect(oct.title == "October 2026")
        #expect(oct.total == "AED 2,500")
        #expect(oct.rows.map(\.label) == ["First Abu Dhabi Bank", "Abu Dhabi Commercial Bank", "Others"])
        #expect(oct.rows.map(\.amount) == ["AED 1,250", "AED 1,150", "AED 100"])
        #expect(oct.rows.map(\.share) == ["50%", "46%", "4%"])
        let sep = try #require(b.callout(forMonthLabel: "Sep"))
        #expect(sep.rows.isEmpty)
        #expect(b.callout(forMonthLabel: "Jan") == nil)
        #expect(SpendBreakdown.shareLabel(Decimal(string: "0.0286")!) == "3%")
        #expect(SpendBreakdown.shareLabel(Decimal(string: "0.0021")!) == "0.2%")
    }

    @Test("an empty range: no groups, months still listed, nothing to stack")
    func empty() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_empty"))
        #expect(b.isEmpty)
        #expect(b.segments.isEmpty)
        #expect(b.monthLabels == ["Sep", "Oct"])
        #expect(ChartAccessibility.breakdown(b, grouping: .merchant).summary == "No spending in this period.")
    }

    @Test("a range that repeats a month name labels with the year")
    func repeatedMonths() throws {
        let json = #"{"group_by":"bank","total":"0","months":["2025-10","2026-10"],"groups":[],"series":[]}"#
        let b = try SpendBreakdown.decode(Data(json.utf8))
        #expect(b.monthLabels == ["Oct 25", "Oct 26"])
    }

    @Test("chart descriptor data: one series per group, stacked maximum, a spoken summary")
    func accessibility() throws {
        let b = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let ax = ChartAccessibility.breakdown(b, grouping: .bank)
        #expect(ax.title == "Monthly spend by bank")
        #expect(ax.categories == ["August 2026", "September 2026", "October 2026"])
        #expect(ax.series.map(\.name) == ["First Abu Dhabi Bank", "Abu Dhabi Commercial Bank", "Others"])
        #expect(ax.series[0].values == [750, 0, 1250])
        #expect(ax.yMax == 2500)
        #expect(ax.summary == "Total AED 3,500. Largest bank: First Abu Dhabi Bank, 57%.")
    }

    @Test("model: None never calls the RPC; a grouping loads once per range; refresh forces")
    @MainActor
    func model() async throws {
        let api = StubAPI()
        api.breakdown = try SpendBreakdown.decode(try fixture("spend_breakdown_bank"))
        let model = SpendSplitModel(api: api)
        let from = CalendarDay(iso: "2026-08-01")!, to = CalendarDay(iso: "2026-10-15")!
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.breakdownCalls.isEmpty)

        model.grouping = .bank
        await model.load(profileCode: "prf_a", from: from, to: to)
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(api.breakdownCalls == [.bank])
        await model.load(profileCode: "prf_a", from: from, to: to, force: true)
        #expect(api.breakdownCalls == [.bank, .bank])

        model.selectedMonth = "Oct"
        #expect(model.callout?.rows.count == 3)
        model.grouping = .merchant
        #expect(model.selectedMonth == nil)
        api.breakdown = nil
        await model.load(profileCode: "prf_a", from: from, to: to)
        #expect(model.state.errorMessage == "No connection to Ledger.")
    }
}
