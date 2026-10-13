import Foundation
import Testing
@testable import LedgerKit

/// PAR-13: the web's Cards → compare accounts, on the Statements screen.
@Suite("Account comparison: shaping and wording")
struct AccountComparisonTests {
    func cycle(_ code: String, account: String, date: String, kind: String = "statement", balance: String? = "100.00",
               utilisation: String? = "0.25", limit: String? = "10000.00") throws -> StatementCycle {
        let json: [String: Any?] = [
            "stmt_code": code, "account_code": account, "bank_code": "FAB", "card_last4": "1234", "kind": kind,
            "statement_date": date, "period_start": nil, "period_end": nil, "due_date": nil,
            "closing_balance": balance, "min_due": nil, "credit_limit": limit, "utilisation": utilisation,
            "line_count": 1, "debits": "0", "credits": "0", "recon_status": nil, "recon_checks": nil, "doc_code": nil,
        ]
        return try LedgerJSON.decode(StatementCycle.self,
                                     from: try JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() }))
    }

    func point(_ bucket: String, account: String?, amount: String) throws -> SpendPoint {
        // spend_series(p_grain => 'month', p_group => 'account'): group_key is the account code.
        let json: [String: Any?] = ["bucket": bucket, "group_key": account, "group_label": "FAB", "color_token": nil,
                                    "amount": amount, "txn_count": 1]
        return try LedgerJSON.decode(SpendPoint.self,
                                     from: try JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() }))
    }

    @Test("the spend window is the last 12 months, this one included, to today")
    func range() {
        let r = AccountComparison.range(today: CalendarDay(iso: "2026-10-14")!)
        #expect(r.from == CalendarDay(iso: "2025-11-01") && r.to == CalendarDay(iso: "2026-10-14"))
        let months = AccountComparison.monthStarts(from: r.from, to: r.to)
        #expect(months.count == 12 && months.first == r.from && months.last == CalendarDay(iso: "2026-10-01"))
    }

    @Test("per account: newest 12 statements, oldest first; history extracts left out")
    func statementTrends() throws {
        var cycles = try (1...14).map { try cycle("stm_\($0)", account: "acc_a", date: String(format: "2025-%02d-25", min($0, 12))) }
        cycles[13] = try cycle("stm_14", account: "acc_a", date: "2026-02-25")
        cycles.append(try cycle("stm_x", account: "acc_a", date: "2026-03-01", kind: "history_extract"))
        cycles.append(try cycle("stm_b", account: "acc_b", date: "2026-01-25"))
        let trends = AccountComparison.statementTrends(cycles)
        #expect(trends["acc_a"]?.count == 12)
        #expect(trends["acc_a"]?.last?.stmtCode == "stm_14")
        #expect(trends["acc_a"]?.contains { $0.stmtCode == "stm_x" } == false)
        let dates = trends["acc_a"]!.map(\.statementDate)
        #expect(dates == dates.sorted())
        #expect(trends["acc_b"]?.map(\.stmtCode) == ["stm_b"])
    }

    @Test("monthly spend: a month without a row is 0; an account without rows is absent")
    func monthlySpend() throws {
        let months = AccountComparison.monthStarts(from: CalendarDay(iso: "2026-08-01")!, to: CalendarDay(iso: "2026-10-14")!)
        let rows = [try point("2026-08-01", account: "acc_a", amount: "120.50"),
                    try point("2026-10-01", account: "acc_a", amount: "30.00"),
                    try point("2026-10-01", account: nil, amount: "9.00")]
        let spend = AccountComparison.monthlySpend(rows, months: months)
        #expect(spend["acc_a"]?.map(\.amount) == [Decimal(string: "120.50")!, 0, 30])
        #expect(spend["acc_b"] == nil && spend.count == 1)
    }

    @Test("cells: the latest server value, captions and spoken summaries as on the web")
    func cells() throws {
        let points = AccountComparison.statementTrends([
            try cycle("s1", account: "a", date: "2026-08-25", balance: "1000.00", utilisation: "0.1", limit: "10000.00"),
            try cycle("s2", account: "a", date: "2026-09-25", balance: "2500.50", utilisation: "0.25", limit: "10000.00"),
        ])["a"]!
        let balance = AccountComparison.balanceCell(points)
        #expect(balance.value == "AED 2,500.50" && balance.caption == "2 statements" && balance.spark?.isEmpty == false)
        #expect(balance.accessibilityLabel.contains("AED 1,000.00 on 25 Aug 2026 to AED 2,500.50 on 25 Sep 2026"))
        let util = AccountComparison.utilisationCell(points)
        #expect(util.value == "25%" && util.caption == "of AED 10,000.00")

        let empty = AccountComparison.balanceCell([])
        #expect(empty.value == "—" && empty.caption == "No statements yet" && empty.spark == nil)
        let noLimit = AccountComparison.utilisationCell(AccountComparison.statementTrends([
            try cycle("s1", account: "a", date: "2026-09-25", utilisation: nil, limit: nil),
        ])["a"]!)
        #expect(noLimit.value == "—" && noLimit.caption == "No credit limit known" && noLimit.spark == nil)
        #expect(AccountComparison.balanceCell(AccountComparison.statementTrends([
            try cycle("s1", account: "a", date: "2026-09-25"),
        ])["a"]!).caption == "25 Sep statement")

        let none = AccountComparison.spendingCell(nil)
        #expect(none.value == "AED 0.00" && none.caption == "None in 12 months" && none.spark == nil)
        let month = CalendarDay(iso: "2026-10-01")!
        let spend = AccountComparison.spendingCell([.init(month: CalendarDay(iso: "2026-09-01")!, amount: 50),
                                                    .init(month: month, amount: Decimal(string: "12.30")!)])
        #expect(spend.value == "AED 12.30" && spend.caption == "Oct so far")
        #expect(spend.accessibilityLabel == "Monthly spending, AED 50.00 in September to AED 12.30 in October so far, over 2 months")
    }

    @Test("sparkline: unit box, gaps break the line, flat sits mid, min/max widen the domain")
    func sparkline() {
        let line = Sparkline([0, 5, 10])
        #expect(line.segments == [[.init(x: 0, y: 1), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0)]])
        #expect(line.last == .init(x: 1, y: 0))

        let gap = Sparkline([1, nil, 3, 4])
        #expect(gap.segments.count == 2 && gap.segments[0].count == 1 && gap.segments[1].count == 2)

        #expect(Sparkline([7, 7]).segments == [[.init(x: 0, y: 0.5), .init(x: 1, y: 0.5)]])
        #expect(Sparkline([5]).segments == [[.init(x: 0.5, y: 0.5)]])
        #expect(Sparkline([nil, nil]).isEmpty && Sparkline([]).isEmpty)

        let util = Sparkline([Decimal(string: "0.25")!, Decimal(string: "0.5")!], min: 0, max: 1)
        #expect(util.segments == [[.init(x: 0, y: 0.75), .init(x: 1, y: 0.5)]])
    }
}

@MainActor
@Suite("Account comparison: loading on the Statements screen")
struct AccountComparisonModelTests {
    @Test("Statements loads the accounts, a year of cycles and monthly spend by account")
    func loads() async throws {
        let api = StubAPI()
        api.accountRows = [LedgerAccount(accountCode: "acc_01hzy3k8w9m2n4p6q8r0s2t4v6", bankCode: "FAB"),
                           LedgerAccount(accountCode: "acc_z", bankCode: "ENBD", status: "closed")]
        api.cycleRows = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        let model = StatementsModel(api: api)
        await model.load(profileCode: "prf_a")
        let comparison = model.comparison
        #expect(api.cycleLimits.contains(AccountComparison.cycleHistoryLimit))
        #expect(comparison.isVisible && comparison.rows.count == 2)
        #expect(comparison.rows.map(\.colorToken) == ["cat-1", "cat-2"])
        let fab = comparison.rows[0]
        #expect(comparison.balanceCell(fab).value == "AED 4,210.55")
        #expect(comparison.utilisationCell(fab).value == "14%")
        #expect(comparison.spendingCell(fab).caption == "None in 12 months")
        #expect(comparison.balanceCell(comparison.rows[1]).caption == "No statements yet")
    }

    @Test("no accounts or a failed accounts read hide the card; a failed spend read only fails its cells")
    func states() async {
        let api = StubAPI()
        let model = AccountComparisonModel(api: api)
        await model.load(profileCode: "prf_a")
        #expect(!model.isVisible)

        api.accountsError = .network("-1009")
        await model.load(profileCode: "prf_b")
        #expect(!model.isVisible)

        api.accountsError = nil
        api.accountRows = [LedgerAccount(accountCode: "acc_a", bankCode: "FAB")]
        await model.load(profileCode: "prf_b")
        #expect(model.isVisible && model.statements.value != nil && model.spending.value != nil)
        model.reset()
        #expect(model.accounts.value == nil && model.months.isEmpty)
    }
}
