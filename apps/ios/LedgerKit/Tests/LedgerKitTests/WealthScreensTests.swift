import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

@Suite("Wealth mode: screen models")
@MainActor
struct WealthScreensTests {
    static func api() throws -> StubAPI {
        let api = StubAPI()
        api.netWorthFixture = try LedgerJSON.decode(NetWorth.self, from: try fixture("net_worth"))
        api.netWorthSeriesFixture = try LedgerJSON.decode([NetWorthPoint].self, from: try fixture("net_worth_series"))
        api.cashPositionFixture = try LedgerJSON.decode(CashPosition.self, from: try fixture("cash_position"))
        api.cashFlowRows = try LedgerJSON.decode([CashFlowRow].self, from: try fixture("cash_flow"))
        api.accountLedgerFixture = try LedgerJSON.decode(AccountLedger.self, from: try fixture("account_ledger"))
        api.balanceSeriesFixture = try LedgerJSON.decode([BalancePoint].self, from: try fixture("bank_balance_series"))
        api.insightRows = [
            Insight(insightCode: "ins_a", kind: "balance_stale", severity: "warn", title: "Stale", body: ""),
            Insight(insightCode: "ins_b", kind: "spend_pace", severity: "alert", title: "Pace", body: ""),
        ]
        return api
    }

    @Test("Wealth's Overview: net worth, history, accounts, this month's flows and only Wealth insights")
    func overview() async throws {
        let api = try Self.api()
        let model = WealthOverviewModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        let content = try #require(model.state.value)
        #expect(content.netWorth.netAed == dec("144700.53"))
        #expect(content.series.count == 3 && content.showsChart)
        #expect(content.position?.accounts.count == 2)
        #expect(content.thisMonth?.month == day("2026-10-01") && content.thisMonth?.net == dec("20398.90"))
        #expect(content.insights.map(\.kind) == ["balance_stale"])
        #expect(content.owingCards.count == 3)
        #expect(api.cashFlowRanges.last?.from == day("2026-10-01") && api.cashFlowRanges.last?.to == day("2026-10-31"))
        #expect(model.monthTitle == "October 2026")
    }

    @Test("Wealth's Overview: the extras failing leave net worth on screen; net worth failing fails it")
    func extrasFail() async throws {
        let api = try Self.api()
        api.netWorthSeriesError = .network("-1009")
        api.cashFlowError = .network("-1009")
        api.cashPositionFixture = nil
        let model = WealthOverviewModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        let content = try #require(model.state.value)
        #expect(content.series.isEmpty && !content.showsChart && content.position == nil && content.thisMonth == nil)

        api.netWorthFixture = nil
        let failing = WealthOverviewModel(api: api)
        await failing.load(profileCode: "prf_a")
        #expect(failing.state.value == nil && failing.state.errorMessage != nil)
    }

    @Test("an account's ledger reads the month on screen and 90 days of balances, once")
    func ledger() async throws {
        let api = try Self.api()
        let model = AccountLedgerModel(api: api, accountCode: "acc_x", today: { day("2026-10-20") })
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(model.state.value?.rows.count == 5 && model.sections.count == 4)
        #expect(api.ledgerRanges.last?.account == "acc_x")
        #expect(api.ledgerRanges.last?.from == day("2026-10-01") && api.ledgerRanges.last?.to == day("2026-10-31"))
        #expect(api.balanceSeriesRanges.last?.from == day("2026-07-23") && api.balanceSeriesRanges.last?.to == day("2026-10-20"))
        #expect(model.series.value?.count == 4)

        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(api.calls("accountLedger") == 1)   // on screen already

        model.month.goBack()
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(api.ledgerRanges.last?.from == day("2026-09-01") && api.ledgerRanges.last?.to == day("2026-09-30"))
        #expect(api.calls("bankBalanceSeries") == 1)   // the chart is the last 90 days whatever the month
        #expect(model.emptyMessage == "No transactions in September 2026.")
    }

    @Test("filing a transfer from the ledger saves it, re-reads the ledger and tells the other screens")
    func filing() async throws {
        let api = try Self.api()
        let model = AccountLedgerModel(api: api, accountCode: "acc_x", today: { day("2026-10-20") })
        var told: [String] = []
        model.onChange = { told.append($0) }
        await model.load(profileCode: "prf_a")
        let txn = try LedgerJSON.decode(LedgerTransaction.self, from: Data("""
        {"txn_code":"txn_1","profile_code":"prf_a","account_code":"acc_x","status":"posted","kind":"transfer_out",
         "direction":"debit","txn_date":"2026-10-13","amount_original":"1500.00","currency_original":"AED",
         "bank_code":"ADCB","account_kind":"current","in_spending":false}
        """.utf8))
        try await model.saveCategory(txn, to: "cat_support", applyToMerchant: true, profileCode: "prf_a")
        #expect(api.recategorised.last?.txn == "txn_1" && api.recategorised.last?.merchant == false)
        #expect(api.calls("accountLedger") == 2 && told == ["prf_a"])

        #expect(await model.transaction("txn_gone", profileCode: "prf_a") == nil)
        #expect(model.errorMessage == "This transaction is no longer in this ledger.")
    }

    @Test("the account ledgers are kept per account and cleared with the ledger")
    func ledgers() throws {
        let api = try Self.api()
        let s = LedgerScreens(api: api, today: { day("2026-10-20") })
        let a = s.accountLedgers.model(for: "acc_a")
        #expect(s.accountLedgers.model(for: "acc_a") === a && s.accountLedgers.model(for: "acc_b") !== a)
        s.stop()
        #expect(s.accountLedgers.model(for: "acc_a") !== a)
    }

    @Test("Cash flow's account filter goes to cash_flow and is forgotten with the ledger")
    func accountFilter() async throws {
        let api = try Self.api()
        let model = CashModel(api: api, today: { day("2026-10-20") })
        await model.load(profileCode: "prf_a")
        #expect(api.cashFlowAccounts.last == .some(nil) && model.accountFilterLabel == "All accounts")
        let first = try #require(model.accountChoices.first)
        await model.setAccountFilter(first.accountCode, profileCode: "prf_a")
        #expect(api.cashFlowAccounts.last == .some(first.accountCode) && model.accountFilterLabel == first.title)
        model.reset()
        #expect(model.accountFilter == nil)
    }
}
