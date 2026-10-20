import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func at(_ iso: String) -> Date { LedgerDates.parseTimestamp(iso)! }

/// 19:00 in Dubai on 20 Oct 2026.
private let now = at("2026-10-20T15:00:00Z")
private let today = day("2026-10-20")

@Suite("Wealth mode: the mode switch and its tabs")
@MainActor
struct AppModeTests {
    @Test("each mode's tabs, in order; Settings and Overview are in both")
    func tabs() {
        #expect(AppMode.spending.tabs == [.overview, .activity, .insights, .budgets, .settings])
        #expect(AppMode.wealth.tabs == [.overview, .accounts, .cashFlow, .settings])
        #expect(AppMode.home(of: .activity) == .spending && AppMode.home(of: .cashFlow) == .wealth)
        #expect(AppMode.home(of: .accounts) == .wealth && AppMode.home(of: .budgets) == .spending)
        #expect(LedgerTab.accounts.title == "Accounts" && LedgerTab.cashFlow.title == "Cash flow")
        #expect(AppMode.wealth.title == "Wealth" && AppMode.spending.title == "Spending")
    }

    @Test("an unknown or missing saved mode is Spending")
    func restored() {
        #expect(AppMode.restored(nil) == .spending)
        #expect(AppMode.restored("investments") == .spending)
        #expect(AppMode.restored("wealth") == .wealth)
    }

    @Test("switching keeps Settings, otherwise opens Overview, and is kept between launches")
    func switching() throws {
        let suite = "ledger-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let router = TabRouter(defaults: defaults)
        #expect(router.mode == .spending)
        router.show(.budgets)
        router.switchMode(.wealth)
        #expect(router.mode == .wealth && router.tab == .overview)
        router.show(.settings)
        router.switchMode(.spending)
        #expect(router.tab == .settings)
        router.switchMode(.wealth)
        #expect(TabRouter(defaults: defaults).mode == .wealth)   // the next launch
        router.reset()
        #expect(router.mode == .wealth && router.tab == .overview)   // a new ledger keeps the mode
    }

    @Test("a link to a tab the mode doesn't show switches mode: Activity and Review are Spending's")
    func links() {
        let router = TabRouter(today: { today })
        router.switchMode(.wealth)
        router.openActivity(.uncategorised(month: today))
        #expect(router.mode == .spending && router.tab == .activity)

        router.switchMode(.wealth)
        router.open(.review, ledgerOnScreen: true)
        #expect(router.mode == .spending && router.tab == .overview && router.showingReview)

        router.switchMode(.wealth)
        router.open(.addStatement, ledgerOnScreen: true)
        #expect(router.mode == .wealth && router.tab == .settings && router.settingsPath == [.statements])

        router.show(.cashFlow)
        #expect(router.mode == .wealth && router.tab == .cashFlow)
        router.follow(.budgets)
        #expect(router.mode == .spending && router.tab == .budgets)
    }
}

@Suite("Wealth mode: net worth")
struct NetWorthTests {
    @Test("net_worth decodes exact decimals, the cards and every caveat")
    func decodes() throws {
        let w = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth"))
        #expect(w.netAed == dec("144700.53") && w.cashAed == dec("158870.15") && w.owedAed == dec("14169.62"))
        #expect(w.heroAmount == "144,701" && w.heroAccessibilityLabel == "Net worth, 144,701 dirhams")
        #expect(w.cashText == "AED 158,870.15" && w.owedText == "≈ AED 14,169.62")
        #expect(w.owedDeductionText == "≈ −AED 14,169.62")
        #expect(w.asOfText(now: now) == "Cash as of 8 Oct")
        #expect(!w.complete && w.completenessTone == .warn)
        #expect(w.caveats == [
            "1 bank account has no balance yet, so cash leaves it out.",
            "1 balance is over a week old.",
            "A card has no statement or balance yet, so what's owed may be short.",
            "What the cards owe includes a foreign-currency estimate.",
        ])
        #expect(w.cards.count == 3)
        #expect(w.cards[0].title == "Everyday" && w.cards[0].detail == "ADCB · Platinum Rewards")
        #expect(w.cards[0].owedText == "AED 8,966.35")
        #expect(w.cards[1].owedText == "≈ AED 5,203.27")
        #expect(w.cards[2].title == "WIO" && w.cards[2].owedText == "Not known yet" && !w.cards[2].isKnown)
    }

    @Test("a negative net reads with a true minus; no bank accounts says where to add one")
    func negativeAndEmpty() {
        let w = NetWorth(cashAed: 0, owedAed: dec("2050.40"), netAed: dec("-2050.40"), complete: true,
                         hasBankAccounts: false)
        #expect(w.heroAmount == "−2,050")
        #expect(w.caveats == ["No bank accounts yet, so this is only what the cards owe. Add one under Accounts."])
        #expect(w.completenessText == "Every bank account and card is counted." && w.completenessTone == .positive)
    }

    @Test("net_worth_series: months oldest first, the live point last; the history note")
    func series() throws {
        let points = try LedgerJSON.decode([NetWorthPoint].self, from: try fixture("net_worth_series"))
        #expect(points.map(\.month) == [day("2026-08-01"), day("2026-09-01"), day("2026-10-01")])
        #expect(points[2].isLive && !points[0].isLive && points[1].netAed == dec("141200.00"))
        #expect(points[2].monthLabel == "Oct")
        #expect(points[2].accessibilityValue == "October 2026, AED 144,700.53, today")
        #expect(NetWorthHistory.showsChart(points))
        #expect(NetWorthHistory.note(points).hasPrefix("Each point is the month's last nightly snapshot"))
        let first = [points[2]]
        #expect(!NetWorthHistory.showsChart(first))
        #expect(NetWorthHistory.note(first).hasPrefix("History starts with the first nightly snapshot"))
    }
}

@Suite("Wealth mode: an account's ledger")
struct AccountLedgerTests {
    @Test("account_ledger decodes the account, the period's figures and the rows newest first")
    func decodes() throws {
        let l = try LedgerJSON.decode(AccountLedger.self, from: try fixture("account_ledger"))
        #expect(l.account.title == "ADCB Salary" && l.account.detail == "ADCB · Current ··· 810001")
        #expect(l.from == day("2026-10-01") && l.to == day("2026-10-31"))
        #expect(l.summaryLines.map(\.text) == ["AED 18,222.55", "+AED 45,000.00", "−AED 6,620.00", "AED 38,420.15"])
        #expect(l.summaryLines.map(\.label) == ["Opening balance", "Money in", "Money out", "Closing balance"])
        #expect(l.summaryLines[1].tone == .positive)
        #expect(l.unpricedNote == "1 transaction isn't in AED, so money in and out leave it out.")
        #expect(l.rows.count == 5)

        let sections = l.sections(today: today)
        #expect(sections.map(\.title) == ["13 Oct", "10 Oct", "4 Oct", "1 Oct"])
        #expect(sections[1].rows.map(\.txnCode) == ["txn_01m5d2t40c615k5c2v9vcyje7b", "txn_01m5d2t40c615k5c2v9vcyje7a"])
    }

    @Test("rows: signed amounts in the account's currency, the balance after, flow chips and captions")
    func rows() throws {
        let l = try LedgerJSON.decode(AccountLedger.self, from: try fixture("account_ledger"))
        let (out, usd, fuel, repay, salary) = (l.rows[0], l.rows[1], l.rows[2], l.rows[3], l.rows[4])
        #expect(out.title == "LOCAL TRANSFER" && out.amountText(currency: "AED") == "−AED 1,500.00")
        #expect(out.balanceText(currency: "AED") == "Balance AED 38,420.15")
        #expect(out.flowLabel == "Unfiled out" && out.flowTone == .warn && out.caption == nil)
        #expect(usd.title == "Amazon" && usd.amountText(currency: "AED") == "−USD 12.00")
        #expect(usd.balanceText(currency: "AED") == nil)
        #expect(fuel.caption == "Car & Fuel" && fuel.flowLabel == "Spending" && fuel.flowTone == .neutral)
        #expect(repay.caption == "Paid to FAB •4417" && repay.flowLabel == "Card repayment")
        #expect(salary.isCredit && salary.amountText(currency: "AED") == "+AED 45,000.00")
        #expect(salary.flowLabel == "Income" && salary.flowTone == .positive && salary.caption == "Salary")
    }

    @Test("a period without balances shows dashes; empty months say which month")
    func unknowns() {
        let account = AccountLedger.Account(accountCode: "acc_x", bankCode: "WIO", kind: "current", accountRef: "5059")
        let l = AccountLedger(account: account, from: day("2026-09-01"), to: day("2026-09-30"), openingBalance: nil,
                              closingBalance: nil, moneyIn: nil, moneyOut: nil, rows: [])
        #expect(l.summaryLines.map(\.text) == ["—", "—", "—", "—"])
        #expect(l.unpricedNote == nil && account.title == "Current ··· 5059")
        #expect(AccountLedger.emptyMessage(day("2026-10-01"), today: today) == "No transactions in October yet.")
        #expect(AccountLedger.emptyMessage(day("2026-09-01"), today: today) == "No transactions in September 2026.")
    }

    @Test("every flow has a chip in the Cash flow vocabulary and a group")
    func flows() {
        let flows = ["income", "money_in", "internal_in", "internal_out", "card_repayment", "support", "saving",
                     "spend", "spend_transfer", "money_out"]
        #expect(flows.map(CashFlowFlow.chipLabel) == ["Income", "Unfiled in", "From own account", "To own account",
                                                      "Card repayment", "Support", "Saving", "Spending",
                                                      "Paid by transfer", "Unfiled out"])
        #expect(flows.allSatisfy { CashFlowFlow.group(of: $0) != nil })
        #expect(CashFlowFlow.group(of: "money_out") == .unfiledOut && CashFlowFlow.group(of: "saving") == .committed)
        #expect(CashFlowFlow.chipLabel("new_flow") == "New Flow" && CashFlowFlow.tone("new_flow") == .neutral)
    }

    @Test("balance series: known days oldest first; a line needs two")
    func balanceSeries() throws {
        let points = try LedgerJSON.decode([BalancePoint].self, from: try fixture("bank_balance_series"))
        #expect(points.count == 4 && points[0].balance == nil)
        #expect(BalanceSeries.known(points).map(\.balance) == [dec("18222.55"), dec("63222.55"), dec("63222.55")])
        #expect(BalanceSeries.showsChart(points))
        #expect(!BalanceSeries.showsChart(Array(points.prefix(2))))
        #expect(BalanceSeries.note(Array(points.prefix(2))).hasPrefix("The balance chart starts"))
    }
}

@Suite("Wealth mode: partial months in cash flow")
struct PartialMonthTests {
    @Test("a month before the first bank evidence is partial: its net isn't presented as a loss")
    func partial() throws {
        let rows = try LedgerJSON.decode([CashFlowRow].self, from: try fixture("cash_flow"))
        let months = CashFlow.months(rows)
        let august = CashFlow.month(day("2026-08-01"), in: months)
        let september = CashFlow.month(day("2026-09-01"), in: months)
        #expect(august.isPartial && august.netTone == .neutral && august.listText == "Partial month")
        #expect(august.netText == "−AED 9,111.51")   // still the server's figure, on the month itself
        #expect(!september.isPartial && september.netTone == .warn && september.listText == "−AED 10,729.97")
        // An older server sends no is_partial.
        let old = try LedgerJSON.decode([CashFlowRow].self,
                                        from: Data(#"[{"month":"2026-10-01","flow":"net","amount_aed":1,"txn_count":1}]"#.utf8))
        #expect(!old[0].isPartial)
    }
}

@Suite("Wealth mode: insights by mode")
@MainActor
struct InsightAreaTests {
    static func insight(_ kind: String, account: String? = nil) -> Insight {
        Insight(insightCode: "ins_\(kind)", kind: kind, severity: "warn", title: kind, body: "",
                data: InsightData(accountCode: account))
    }

    @Test("the bank-account kinds are Wealth's; annual_fee and unknown kinds stay in Spending")
    func areas() {
        let acc = "acc_01m5d2t4053n2zjr96d7rzyhac"
        #expect(Self.insight("balance_stale").area == .wealth && Self.insight("salary_late").area == .wealth)
        #expect(Self.insight("balance_drift").area == .wealth && Self.insight("annual_fee").area == .spending)
        #expect(Self.insight("brand_new").area == .spending)
        #expect(Self.insight("balance_stale", account: acc).wealthTarget == .account(accountCode: acc))
        #expect(Self.insight("salary_late").wealthTarget == .cashFlow)
        #expect(Self.insight("balance_drift", account: "not-a-code").wealthTarget == nil)
        #expect(Self.insight("spend_pace").wealthTarget == nil)
        #expect(InsightFeed.group([Self.insight("annual_fee")]).map(\.label) == ["Cards"])
    }

    @Test("insights.data's account_code decodes, and a malformed one is dropped")
    func decodesAccount() throws {
        let json = #"{"category_code": null, "account_code": "acc_01m5d2t4053n2zjr96d7rzyhac", "as_of": null}"#
        let data = try LedgerJSON.decode(InsightData.self, from: Data(json.utf8))
        #expect(data.accountCode == "acc_01m5d2t4053n2zjr96d7rzyhac")
        #expect(try LedgerJSON.decode(InsightData.self, from: Data(#"{"account_code": "x"}"#.utf8)).accountCode == nil)
    }

    @Test("Spending's Overview and feed leave the Wealth kinds out")
    func spendingLeavesWealthOut() async throws {
        let api = StubAPI()
        api.overviewFixture = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        api.insightRows = [Self.insight("balance_stale"), Self.insight("spend_pace"), Self.insight("salary_late")]
        let overview = OverviewModel(api: api)
        await overview.load(profileCode: "prf_a")
        #expect(overview.state.value?.insights.map(\.kind) == ["spend_pace"])
        let feed = InsightFeedModel(api: api)
        await feed.load(profileCode: "prf_a")
        #expect(feed.groups?.flatMap(\.items).map(\.kind) == ["spend_pace"] && feed.summary == "1 to look at")
    }
}

@Suite("Wealth mode: Spending's Activity scope and the Debit tag")
struct SpendingScopeTests {
    @Test("every Activity read is scoped to spending, so totals agree with the rows; filters don't count it")
    func scope() {
        var q = ActivityQuery()
        #expect(q.spendingOnly && q.restFilters == [.isTrue("in_spending")])
        #expect(q.activityFilter == ["scope": "spending"])
        #expect(q.summaryParams(profileCode: "prf_a")["p_scope"] == .string("spending"))
        #expect(q.filterCount == 0 && !q.hasFilters)
        q.status = .void
        q.clearFilters()
        #expect(q.spendingOnly)
    }

    @Test("a bank-account row is tagged Debit; a card row, or one from an older server, isn't")
    func debitTag() throws {
        func txn(_ extra: String) throws -> LedgerTransaction {
            let json = """
            {"txn_code":"txn_1","profile_code":"prf_a","account_code":"acc_1","status":"posted","kind":"purchase",
             "direction":"debit","txn_date":"2026-10-10","amount_original":"120.00","currency_original":"AED",
             "bank_code":"ADCB"\(extra)}
            """
            return try LedgerJSON.decode(LedgerTransaction.self, from: Data(json.utf8))
        }
        let debit = try txn(#", "account_kind":"current", "in_spending":true"#)
        #expect(debit.isDebit && debit.paymentTag == "Debit" && debit.inSpending)
        #expect(try txn(#", "account_kind":"savings""#).paymentTag == "Debit")
        let card = try txn(#", "account_kind":"credit_card""#)
        #expect(!card.isDebit && card.paymentTag == nil)
        let old = try txn("")
        #expect(old.accountKind == nil && old.paymentTag == nil && old.inSpending)
    }
}
