import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

/// The fixtures are the local stack's answers for the demo ledger (21 Oct 2026): metals, an
/// RL360 plan in USD with linked card payments, an IBKR account, Example Co shares and a Wio deposit.
enum KindsFixtures {
    static func valuation() throws -> HoldingsValuation {
        try LedgerJSON.decode(HoldingsValuation.self, from: try fixture("holdings_valuation_kinds"))
    }
    static func detail() throws -> HoldingDetail { try LedgerJSON.decode(HoldingDetail.self, from: try fixture("holding_detail")) }
    static func returns(_ name: String = "holding_returns") throws -> HoldingReturns {
        try LedgerJSON.decode(HoldingReturns.self, from: try fixture(name))
    }
    static func holding(_ name: String) throws -> Holding {
        try #require(try valuation().holdings.first { $0.name == name })
    }
    static let plan = "hld_01k5exhvq8k52tcna0y76gqrp2"
}

@Suite("Investments: every kind on the wire")
struct HoldingKindsDecodingTests {
    @Test("holdings_valuation: each kind with its own currency, value, as-of and fields")
    func kinds() throws {
        let v = try KindsFixtures.valuation()
        #expect(v.holdingsCount == 8 && v.valueAed == dec("1048478.23") && !v.costsComplete)
        let plan = try KindsFixtures.holding("RL360 plan")
        #expect(plan.kind == .plan && plan.currency == "USD" && plan.value == dec("53800.00"))
        #expect(plan.valueAed == dec("197580.50") && plan.valueAsOf == day("2026-10-01") && plan.linkPattern == "RL360")
        #expect(plan.metal == nil && plan.grams == nil && plan.form == nil && plan.imagePath == nil && plan.flowCount == 9)
        let deposit = try KindsFixtures.holding("Wio fixed deposit")
        #expect(deposit.isEstimate && deposit.principal == dec("100000.00") && deposit.ratePct == dec("4.250"))
        #expect(deposit.maturityOn == day("2027-06-23") && deposit.acquiredOn == day("2026-06-23"))
        let shares = try KindsFixtures.holding("Example Co shares")
        #expect(shares.kind == .security && shares.units == dec("20000") && shares.symbol == "EXCO")
        let ibkr = try KindsFixtures.holding("IBKR account")
        #expect(ibkr.incomeAed == dec("440.70") && ibkr.institution == "Interactive Brokers")
        let bar = try KindsFixtures.holding("1 kg bar")
        #expect(bar.kind == .metal && bar.metal == .gold && bar.form == .bar && bar.imagePath == "gold-bar.jpg")
    }

    @Test("the value series: a day missing a holding's value says so; an older server's null day is incomplete")
    func series() throws {
        let json = #"[{"date": "2026-10-20", "value_aed": "10.00", "cost_aed": "5.00", "complete": false},"#
            + #"{"date": "2026-10-21", "value_aed": "12.00", "cost_aed": "5.00", "complete": true}]"#
        let points = try LedgerJSON.decode([HoldingValuePoint].self, from: Data(json.utf8))
        #expect(points.map(\.complete) == [false, true] && InvestmentsChart.partialNote(points) != nil)
        let old = try LedgerJSON.decode([HoldingValuePoint].self, from: try fixture("holdings_value_series"))
        #expect(old.allSatisfy(\.complete) && InvestmentsChart.partialNote(old) == nil)
    }

    @Test("a server before kinds: every holding is a metal valued in AED")
    func legacy() throws {
        let v = try InvestmentsDecodingTests.valuation()
        #expect(v.holdings.allSatisfy { $0.kind == .metal && $0.currency == "AED" && $0.value == $0.valueAed })
        #expect(v.groups.map(\.kind) == [.metal])
    }

    @Test("the holdings group by kind in a fixed order, each in the server's order, with no subtotal")
    func groups() throws {
        let v = try KindsFixtures.valuation()
        #expect(v.groups.map(\.kind) == [.metal, .plan, .broker, .security, .deposit])
        #expect(v.groups.first?.holdings.map(\.name) == ["1 kg bar", "Silver bars", "Ten tola bar", "Bangles"])
        #expect(v.groups.first?.countText == "4 holdings" && v.groups.last?.title == "Fixed deposits")
        #expect(v.showsMetalPrices && v.holding(KindsFixtures.plan)?.name == "RL360 plan")
        #expect(v.caveats.contains("Fixed deposits are estimated: profit accrues each day to maturity."))
        let noMetals = HoldingsValuation(valueAed: 1, holdings: [Holding(holdingCode: "h", name: "P", kind: .plan)])
        #expect(!noMetals.showsMetalPrices && HoldingsValuation(valueAed: 0).showsMetalPrices)
    }
}

@Suite("Investments: a row for every kind")
struct HoldingKindsPresentationTests {
    let today = day("2026-10-21")

    @Test("detail lines, own-currency value, as-of and estimate")
    func rows() throws {
        let plan = try KindsFixtures.holding("RL360 plan")
        #expect(plan.detail(today: today) == "RL360 · USD" && plan.ownValueText == "USD 53,800.00")
        #expect(plan.valueText == "AED 197,580.50" && plan.asOfText(today: today) == "Value as of 1 Oct")
        #expect(plan.changeText == nil && plan.gainText == "−AED 2,198.00 (−1.10%)" && !plan.hasPhoto)
        let deposit = try KindsFixtures.holding("Wio fixed deposit")
        #expect(deposit.detail(today: today) == "Wio · 4.25% · matures 23 Jun 2027")
        #expect(deposit.asOfText(today: today) == "Profit accrued to 21 Oct" && deposit.estimateLabel == "Estimated")
        #expect(deposit.changeText == "+AED 11.64 in 24h" && deposit.ownValueText == nil)
        let shares = try KindsFixtures.holding("Example Co shares")
        #expect(shares.detail(today: today) == "EXCO · 20,000 units" && shares.asOfText(today: today) == "Price as of 20 Oct")
        let ibkr = try KindsFixtures.holding("IBKR account")
        #expect(ibkr.incomeText == "Income AED 440.70" && ibkr.canRecordValue && !deposit.canRecordValue)
        let bar = try KindsFixtures.holding("1 kg bar")
        #expect(bar.asOfText(today: today) == nil && bar.hasPhoto && bar.changeText == nil)
        let bangles = try KindsFixtures.holding("Bangles")
        #expect(bangles.noGainText == "No cost entered")
        #expect(Holding(holdingCode: "x", name: "New", kind: .broker).valueText == "No value yet")
        #expect(Holding(holdingCode: "x", name: "New", kind: .broker, valueAed: 5).noGainText == "No money in recorded")
        #expect(HoldingsText.units(dec("12.500000")) == "12.5 units" && HoldingsText.units(1) == "1 unit")
    }

    @Test("a recorded value over 45 days old asks for a newer one")
    func stale() {
        let now = Date(timeIntervalSince1970: 1_792_540_800)   // 2026-10-21 04:00 Dubai
        let h = Holding(holdingCode: "h", name: "Plan", kind: .plan, valueAsOf: day("2026-08-01"), priceIsStale: true)
        #expect(h.staleText(now: now) == "The value is from 1 Aug, over 45 days ago. Record a newer one.")
        #expect(Holding(holdingCode: "h", name: "Plan", kind: .plan).staleText(now: now) == nil)
    }

    @Test("kinds: labels, groups, symbols and what each records")
    func kinds() {
        #expect(HoldingKind.allCases.map(\.label) == ["Gold or silver", "Plan", "Broker account", "Shares or fund", "Fixed deposit"])
        #expect(HoldingKind.allCases.filter(\.recordsValue) == [.plan, .broker, .security])
        #expect(!HoldingKind.metal.takesFlows && HoldingKind.deposit.takesFlows)
        #expect(Set(HoldingKind.allCases.map(\.systemImage)).count == 5)
    }
}

@Suite("Investments: the form for every kind")
struct HoldingKindsDraftTests {
    let today = day("2026-10-21")

    func draft(_ kind: HoldingKind) -> HoldingDraft {
        var d = HoldingDraft(today: today, kind: kind)
        d.name = "Thing"
        return d
    }

    @Test("a plan: currency, institution and a payment rule; no cost, no metal")
    func plan() throws {
        var d = draft(.plan)
        d.currency = "USD"
        d.institution = " RL360 "
        d.linkPattern = "RL"
        #expect(d.validate(today: today)?.hasPrefix("A 2-character rule must match the whole description") == true)
        d.linkPattern = " RL360 "
        let s = try #require(d.submission(today: today))
        #expect(s.kind == .plan && s.currency == "USD" && s.institution == "RL360" && s.linkPattern == "RL360")
        #expect(s.metal == nil && s.grams == nil && s.costAed == nil && s.units == nil && s.acquiredOn == nil)
        #expect(HoldingDraft(today: today, kind: .plan).validate(today: today) == "Give the holding a name, e.g. RL360 Quantum.")
        let params = SupabaseLedgerAPI.saveHoldingParams(profileCode: "prf_a", holding: s)
        #expect(params["p_kind"] == .string("plan") && params["p_currency"] == .string("USD"))
        #expect(params["p_metal"] == .null && params["p_grams"] == .null && params["p_link_pattern"] == .string("RL360"))
    }

    @Test("shares: units up to six decimals and an upper-cased symbol")
    func security() throws {
        var d = draft(.security)
        #expect(d.validate(today: today)?.hasPrefix("Enter the units you hold") == true)
        d.units = "1,000.1234567"
        #expect(d.validate(today: today)?.hasPrefix("Enter the units") == true)
        d.units = "20,000"
        d.symbol = "exco"
        let s = try #require(d.submission(today: today))
        #expect(s.units == "20000" && s.symbol == "EXCO" && s.principal == nil)
    }

    @Test("a deposit: principal, rate, a start date always sent, and a later maturity")
    func deposit() throws {
        var d = draft(.deposit)
        #expect(d.validate(today: today) == "Enter the amount deposited, e.g. 100000.")
        d.principal = "100,000"
        d.ratePct = "101"
        #expect(d.validate(today: today) == "Enter the profit rate a year in percent, e.g. 4.25.")
        d.ratePct = "4.25"
        d.maturityOn = today
        #expect(d.validate(today: today) == "The maturity date must be after the start date.")
        d.maturityOn = day("2027-06-23")
        d.acquiredOn = day("2026-10-22")
        d.maturityOn = day("2027-10-22")
        #expect(d.validate(today: today) == "The start date can't be in the future.")
        d.acquiredOn = day("2026-06-23")
        let s = try #require(d.submission(today: today))
        #expect(s.principal == "100000" && s.ratePct == "4.25" && s.acquiredOn == day("2026-06-23"))
        #expect(s.maturityOn == day("2027-10-22") && !d.asksDateToggle && d.dateTitle == "Start date")
    }

    @Test("editing starts from the server's holding; the kind can't change")
    func edit() throws {
        let deposit = HoldingDraft(holding: try KindsFixtures.holding("Wio fixed deposit"), today: today)
        #expect(deposit.kind == .deposit && !deposit.canChangeKind && deposit.principal == "100000.00")
        #expect(deposit.ratePct == "4.25" && deposit.maturityOn == day("2027-06-23") && deposit.cost == "")
        let shares = HoldingDraft(holding: try KindsFixtures.holding("Example Co shares"), today: today)
        #expect(shares.units == "20000" && shares.symbol == "EXCO" && shares.institution == "DFM")
        let plan = HoldingDraft(holding: try KindsFixtures.holding("RL360 plan"), today: today)
        #expect(plan.currency == "USD" && plan.linkPattern == "RL360" && plan.currencyChoices.contains("USD"))
        #expect(HoldingDraft(today: today).canChangeKind && HoldingDraft(today: today, kind: .broker).afterAddNote != nil)
    }

    @Test("a metal still sends its weight, and its rule if given")
    func metal() throws {
        var d = draft(.metal)
        d.weight = "10"
        d.unit = .tola
        let s = try #require(d.submission(today: today))
        #expect(s.kind == .metal && s.grams == "116.638" && s.currency == nil && s.linkPattern == nil)
        let params = SupabaseLedgerAPI.saveHoldingParams(profileCode: "prf_a", holding: s)
        #expect(params["p_kind"] == .string("metal") && params["p_metal"] == .string("gold") && params["p_form"] == .string("bar"))
    }
}

@Suite("Investments: flows, values and returns")
struct HoldingFlowsTests {
    let today = day("2026-10-21")

    @Test("holding_detail: linked payments name their bank, manual flows say so")
    func detail() throws {
        let d = try KindsFixtures.detail()
        #expect(d.flows.count == 9 && d.valuations.count == 2)
        let linked = try #require(d.flows.first)
        #expect(linked.isLinked && linked.title == "RL360 PLAN" && linked.source == "rule")
        #expect(linked.caption == "Money in · ADCB account · linked by its rule")
        #expect(linked.amountText(currency: "USD") == "+USD 1,362.40" && linked.aedText(currency: "USD") == "AED 5,000.00")
        #expect(linked.removeTitle == "Unlink" && linked.canRemove)
        let card = d.flows[1]
        #expect(card.caption == "Money in · ADCB card · linked by its rule")
        let manual = try #require(d.flows.last)
        #expect(!manual.isLinked && manual.title == "Money in" && manual.caption == "Money in · added by hand")
        #expect(manual.removeTitle == "Remove")
        #expect(d.valuations.first?.text(currency: "USD") == "USD 53,800.00" && d.valuations.first?.asOf == day("2026-10-01"))
        let cost = HoldingFlow(flowCode: "f", flowDate: today, kind: .contribution, amount: 1, amountAed: 1, source: "holding_cost")
        #expect(!cost.canRemove && cost.title == "What you paid")
        let income = HoldingFlow(flowCode: "i", flowDate: today, kind: .income, amount: 120, amountAed: 120)
        #expect(income.amountText(currency: "AED") == "AED 120.00" && income.amountTone == .positive)
    }

    @Test("a flow: amount in the holding's currency, AED optional for a foreign one, not in the future")
    func flowDraft() throws {
        var d = FlowDraft(holding: try KindsFixtures.holding("RL360 plan"), today: today)
        #expect(d.asksAed && d.aedNote.contains("3.6725"))
        #expect(d.validate(today: today) == "Enter the amount in USD as a number above 0, e.g. 2000.")
        d.amount = "2,000"
        d.amountAed = "abc"
        #expect(d.validate(today: today) == "Enter the AED amount as a number above 0, or leave it empty.")
        d.amountAed = ""
        d.date = day("2026-10-22")
        #expect(d.validate(today: today) == "The date can't be in the future.")
        d.date = today
        d.kind = .income
        d.notes = " Dividend "
        let s = try #require(d.submission(today: today))
        #expect(s.amount == "2000" && s.amountAed == nil && s.kind == .income && s.notes == "Dividend")
        #expect(d.savedMessage == "Income added to RL360 plan.")
        var aed = FlowDraft(holding: try KindsFixtures.holding("Wio fixed deposit"), today: today)
        aed.amount = "500"
        aed.amountAed = "999"
        #expect(!aed.asksAed && aed.submission(today: today)?.amountAed == nil)
    }

    @Test("a value: a whole value for a plan, a unit price for shares")
    func valueDraft() throws {
        var plan = ValueDraft(holding: try KindsFixtures.holding("RL360 plan"), today: today)
        #expect(plan.fieldTitle == "Value in USD" && plan.title == "Update value")
        #expect(plan.validate(today: today) == "Enter the value in USD, e.g. 53800.")
        plan.amount = "54,100.50"
        #expect(plan.submission(today: today) == ValueSubmission(holdingCode: KindsFixtures.plan, value: "54100.50", asOf: today))
        var shares = ValueDraft(holding: try KindsFixtures.holding("Example Co shares"), today: today)
        shares.amount = "1.4235"
        let s = try #require(shares.submission(today: today))
        #expect(s.unitPrice == "1.4235" && s.value == nil && shares.fieldTitle == "Price per unit in AED")
        #expect(shares.savedMessage == "Example Co shares's price updated.")
    }

    @Test("returns: all time is whole; this year leaves out the holdings with no start value")
    func returns() throws {
        let all = try KindsFixtures.returns()
        #expect(all.total.complete && all.total.annualPct == dec("14.52") && all.from == nil && all.incompleteNote == nil)
        #expect(all.total.annualText == "+14.52%" && all.rangeText == "All time")
        let labels = all.total.lines(period: .all).map(\.label)
        #expect(labels == ["Money added", "Income", "Value now", "Growth", "Return"])
        let plan = try #require(all.figures(for: KindsFixtures.plan))
        #expect(plan.kind == .plan && plan.figures.growthAed == dec("-2198.00") && plan.figures.annualPct == dec("-1.28"))
        let ytd = try KindsFixtures.returns("holding_returns_ytd")
        #expect(!ytd.total.complete && ytd.from == day("2026-01-01") && ytd.incomplete.count == 4)
        #expect(ytd.incompleteNote
                == "Left out: 1 kg bar, IBKR account, RL360 plan and Silver bars had no value on 1 Jan 2026, so the total covers the rest.")
        let missing = try #require(ytd.figures(for: KindsFixtures.plan))
        #expect(missing.figures.startValueAed == nil && missing.figures.annualText == nil)
        #expect(ytd.total.lines(period: .ytd).first?.label == "Value at start")
        #expect(ReturnsPeriod.allCases.map(\.title) == ["All", "This year", "12 months"] && ReturnsPeriod.twelveMonths.rawValue == "12m")
    }
}

@Suite("Investments: allocation, saving by holding and links")
struct InvestmentLinksTests {
    @Test("net_worth.allocation: assets largest first, owed apart as a negative line")
    func allocation() throws {
        let worth = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth_allocation"))
        let assets = Allocation.assets(worth.allocation)
        #expect(assets.map(\.assetClass) == ["gold", "plan", "cash", "deposit", "silver", "broker", "security"])
        #expect(assets.first?.label == "Gold" && assets.first?.shareText == "49.2%" && assets.first?.valueText == "AED 593,370.64")
        let owed = try #require(Allocation.owed(worth.allocation))
        #expect(owed.label == "Owed on cards" && owed.valueText == "−AED 52,048.12" && owed.shareText == nil)
        #expect(Allocation.showsChart(worth.allocation) && Set(assets.map(\.colorToken)).count == assets.count)
        #expect(assets.last?.accessibilityLabel == "Shares and funds, AED 28,400.00, 2.4% of assets")
        let old = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth"))
        #expect(old.allocation.isEmpty && !Allocation.showsChart(old.allocation))
    }

    @Test("cash_flow_savings: each holding then Unassigned, for the month asked")
    func savings() throws {
        var rows = try LedgerJSON.decode([SavingByHolding].self, from: try fixture("cash_flow_savings"))
        rows.append(SavingByHolding(month: day("2026-10-01"), amountAed: 300, txnCount: 1))
        let lines = CashFlowSavings.lines(rows, month: day("2026-10-15"))
        #expect(lines.map(\.label) == ["RL360 plan", "Unassigned"] && lines.first?.amountText == "AED 12,575.50")
        #expect(lines.first?.countText == "2 transactions" && lines.first?.kind == .plan && lines.last?.systemImage == "tray")
        #expect(CashFlowSavings.showsBreakdown(lines))
        #expect(!CashFlowSavings.showsBreakdown([lines[1]]) && CashFlowSavings.lines(rows, month: day("2026-01-01")).isEmpty)
    }

    @Test("Cash flow asks for saving by holding for the same accounts; failing, it leaves the split out")
    @MainActor
    func cashModel() async throws {
        let api = try WealthScreensTests.api()
        api.savingsFixture = try LedgerJSON.decode([SavingByHolding].self, from: try fixture("cash_flow_savings"))
        let model = CashModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        #expect(model.selectedSavings.map(\.label) == ["RL360 plan"])
        #expect(api.savingsRanges.last?.from == day("2026-05-01") && api.savingsRanges.last?.to == day("2026-10-31"))
        api.savingsFixture.append(SavingByHolding(month: day("2026-10-01"), amountAed: 50))
        await model.load(profileCode: "prf_a")
        #expect(model.selectedSavings.map(\.label) == ["RL360 plan", "Unassigned"])
        let account = try #require(model.accountChoices.first?.accountCode)
        await model.setAccountFilter(account, profileCode: "prf_a")
        #expect(api.savingsRanges.last?.account == account && api.calls("cashFlowSavings") == 3)
        #expect(api.savingsRanges.first?.account == nil)
        api.savingsError = .network("-1009")
        await model.setAccountFilter(nil, profileCode: "prf_a")
        #expect(model.state.value != nil && model.selectedSavings.isEmpty && model.state.value?.flowError == nil)
    }

    @Test("a linked row names its holding, in Activity and the account ledger")
    func linkedRows() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: try fixture("transactions")) as? [[String: Any]]).first!
        json["holding_code"] = KindsFixtures.plan
        json["holding_name"] = "RL360 plan"
        let linked = try LedgerJSON.decode(LedgerTransaction.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(linked.holdingCode == KindsFixtures.plan && linked.holdingChipLabel == "Saving · RL360 plan")
        #expect(txn("t1").holdingChipLabel == nil)
        let row = AccountLedgerRow(txnCode: "t", txnDate: day("2026-10-04"), amount: 5000, flow: "saving", balanceAfter: nil,
                                   holdingCode: KindsFixtures.plan, holdingName: "RL360 plan")
        #expect(row.flowLabel == "Saving · RL360 plan")
        #expect(AccountLedgerRow(txnCode: "t", txnDate: day("2026-10-04"), amount: 1, flow: "saving", balanceAfter: nil).flowLabel == "Saving")
    }
}
