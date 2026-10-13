import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

/// Overview JSON with one account; `latest` is spliced into `latest_statement` (UX-1r).
private func overview(latest: String = "") throws -> Overview {
    let json = """
    {"month": "2026-10-01", "spend": "860", "spend_prev_month": "0", "spend_prev_month_to_date": "0",
     "spend_avg_3m": "0", "payments": "0", "pending_count": 2, "pending_amount": "3105.30",
     "uncategorized_count": 0, "open_reviews": 0, "last_sms_at": null, "top_categories": [], "recent": [],
     "accounts": [{"account_code": "acc_01hzy3k8w9m2n4p6q8r0s2t4v6", "bank_code": "FAB", "nickname": null,
       "product_name": null, "credit_limit": null, "last4": null, "unbilled_aed": "0",
       "latest_statement": {"stmt_code": "stm_01hzy3k8w9m2n4p6q8r0s2t4v6", "statement_date": "2026-09-25",
         "due_date": "2026-10-20", "closing_balance": "4210.55", "min_due": "210.53"\(latest)}}]}
    """
    return try LedgerJSON.decode(Overview.self, from: Data(json.utf8))
}

private func cycle(_ extra: String = "") throws -> StatementCycle {
    let json = """
    [{"stmt_code": "stm_01hzy3k8w9m2n4p6q8r0s2t4v6", "account_code": "acc_01hzy3k8w9m2n4p6q8r0s2t4v6",
      "bank_code": "FAB", "card_last4": "1234", "kind": "statement", "statement_date": "2026-09-25",
      "period_start": null, "period_end": null, "due_date": "2026-10-20", "closing_balance": 4210.55,
      "min_due": 210.53, "credit_limit": null, "utilisation": null, "line_count": 3, "debits": 10, "credits": 0,
      "recon_status": null, "recon_checks": null, "doc_code": null\(extra)}]
    """
    return try #require(LedgerJSON.decode([StatementCycle].self, from: Data(json.utf8)).first)
}

@Suite("Dues: Paid / Part paid / Overdue from the server's payment_status (UX-1r)")
struct DuePaymentTests {
    let today = CalendarDay(iso: "2026-10-08")!

    // MARK: decoding, with and without the fields

    @Test("an older server: no payment fields, nothing claimed")
    func olderServer() throws {
        let o = try overview()
        let account = try #require(o.accounts.first)
        #expect(account.duePayment == nil)
        #expect(AccountSummary(account: account).due(today: today)! == ("Due in 12 days", .neutral))
        let c = try cycle()
        #expect(c.paymentStatus == nil && c.amountPaid == nil && c.duePayment == nil)
        #expect(c.due(isLatest: true, today: today)! == ("Due in 12 days", .neutral))
    }

    @Test("latest_statement carries the status and the amount paid (a decimal string)")
    func onLatestStatement() throws {
        let o = try overview(latest: #", "payment_status": "part_paid", "amount_paid": "1200.50""#)
        let account = try #require(o.accounts.first)
        #expect(account.duePayment == DuePayment(status: .partPaid, amountPaid: dec("1200.50")))
        #expect(AccountSummary(account: account).due(today: today)! == ("Part paid (AED 1,200.50) · Due in 12 days", .warn))
    }

    @Test("statement_detail's header: decoded when present, absent from an older server")
    func statementDetail() throws {
        func header(_ extra: String) throws -> StatementDetail.Header {
            let json = """
            {"statement": {"stmt_code": "stm_01hzy3k8w9m2n4p6q8r0s2t4v6", "account_code": "acc_01hzy3k8w9m2n4p6q8r0s2t4v6",
              "statement_date": "2026-09-25", "due_date": "2026-09-30"\(extra)},
             "debits": {"lines": [], "total": "0", "count": 0}, "credits": {"lines": [], "total": "0", "count": 0}}
            """
            return try LedgerJSON.decode(StatementDetail.self, from: Data(json.utf8)).statement
        }
        let older = try header("")
        #expect(older.duePayment == nil)
        #expect(older.due(isLatest: true, today: today)! == ("Was due 30 Sep", .neutral))
        let overdue = try header(#", "payment_status": "overdue", "amount_paid": "1510.82""#)
        #expect(overdue.duePayment == DuePayment(status: .overdue, amountPaid: dec("1510.82")))
        #expect(overdue.due(isLatest: true, today: today)! == ("Overdue by 8 days · AED 1,510.82 paid", .danger))
    }

    @Test("statement_cycles: decoded when present, a number amount too")
    func cycles() throws {
        let c = try cycle(#", "payment_status": "paid", "amount_paid": 4210.55"#)
        #expect(c.duePayment == DuePayment(status: .paid, amountPaid: dec("4210.55")))
        #expect(c.due(isLatest: true, today: today)! == ("Paid", .positive))
        let nulls = try cycle(#", "payment_status": null, "amount_paid": null"#)
        #expect(nulls.duePayment == nil)
    }

    @Test("an unknown status from a newer server is ignored, not guessed at")
    func unknownStatus() throws {
        let c = try cycle(#", "payment_status": "refunded""#)
        #expect(c.paymentStatus == "refunded")
        #expect(c.duePayment == nil)
        #expect(c.due(isLatest: true, today: today)! == ("Due in 12 days", .neutral))
    }

    // MARK: wording

    @Test("wording for each status, upcoming and past", arguments: [
        (DuePayment.Status.paid, nil as String?, "2026-09-25", "Paid", Tone.positive),
        (.paid, "100", "2026-10-20", "Paid", .positive),
        (.partPaid, "1200", "2026-10-10", "Part paid (AED 1,200.00) · Due in 2 days", .warn),
        (.partPaid, nil, "2026-09-25", "Part paid · Was due 25 Sep", .warn),
        (.overdue, nil, "2026-09-25", "Overdue by 13 days", .danger),
        (.overdue, "500", "2026-09-25", "Overdue by 13 days · AED 500.00 paid", .danger),
        (.unpaid, nil, "2026-10-20", "Due in 12 days", .neutral),
        (.unpaid, "0", "2026-09-25", "Overdue by 13 days", .danger),
    ])
    func wording(status: DuePayment.Status, paid: String?, due: String, text: String, tone: Tone) {
        let payment = DuePayment(status: status, amountPaid: paid.map(dec))
        let result = DueStatus.describe(due: CalendarDay(iso: due)!, isLatest: true, payment: payment, today: today)
        #expect(result! == (text, tone))
    }

    @Test("an unpaid statement superseded by a newer one is not overdue; paid shows without a due date")
    func edges() {
        let past = CalendarDay(iso: "2026-09-25")!
        #expect(DueStatus.describe(due: past, isLatest: false, payment: .init(status: .unpaid), today: today)!
                == ("Was due 25 Sep", .neutral))
        #expect(DueStatus.describe(due: nil, isLatest: true, payment: .init(status: .paid), today: today)! == ("Paid", .positive))
        #expect(DueStatus.describe(due: nil, isLatest: true, payment: .init(status: .unpaid), today: today) == nil)
    }
}

@Suite("Overview hero: the server's spend, SMS and payment charges in it, never set apart")
struct HeroSpendTests {
    let october = CalendarDay(iso: "2026-10-08")!

    @Test("current month: \"so far\", no pending line or spoken pending (the server's pending fields are ignored)")
    func soFar() throws {
        let o = try overview()
        #expect(o.heroEyebrow(today: october) == "October 2026 · so far")
        #expect(o.heroAccessibilityLabel(today: october) == "October spend so far, 860 dirhams")
    }

    @Test("a past month: the month alone")
    func pastMonth() throws {
        let o = try overview()
        #expect(o.heroEyebrow(today: CalendarDay(iso: "2026-11-02")!) == "October 2026")
        #expect(o.heroAccessibilityLabel(today: CalendarDay(iso: "2026-11-02")!) == "October spend, 860 dirhams")
    }

    @Test("no last-card-alert line before the first alert")
    func lastCardAlert() throws {
        #expect(try overview().lastCardAlertLabel(today: october) == nil)
    }
}
