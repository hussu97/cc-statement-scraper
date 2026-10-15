import Foundation
import Testing
@testable import LedgerKit

@Suite("Wire shapes — the same JSON PostgREST and the RPCs return")
struct ModelDecodingTests {
    @Test("overview: jsonb strings and jsonb numbers both decode exactly")
    func overview() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        #expect(o.month.iso == "2026-10-01")
        #expect(MoneyFormat.plain(o.spend) == "1234567.89")
        #expect(o.topCategories[0].amount == Decimal(string: "812.45")!)
        #expect(o.topCategories[1].amount == Decimal(string: "0.3")!)
        #expect(o.topCategories[1].displayName == "Uncategorised")
        #expect(o.accounts[0].creditLimit == Decimal(string: "30000")!)
        #expect(o.accounts[0].cardsLabel == "•1234, •5678")
        #expect(o.accounts[0].latestStatement?.dueDate?.iso == "2026-10-20")
        #expect(o.accounts[1].latestStatement == nil)
        #expect(o.accounts[1].title == "ADCB")
        #expect(o.recent[0].amountLabel == "AED 45.10")
        #expect(o.recent[0].badge == .sms)
        #expect(o.heroAmount == "1,234,568")
        #expect(o.lastCardAlertLabel(today: CalendarDay(iso: "2026-10-08")!) == "Last card alert 09:12")
        #expect(o.lastCardAlertLabel(today: CalendarDay(iso: "2026-10-10")!) == "Last card alert 8 Oct")
    }

    @Test("v_transactions rows")
    func transactions() throws {
        let rows = try LedgerJSON.decode([LedgerTransaction].self, from: try fixture("transactions"))
        #expect(rows.count == 2)
        let fx = rows[0]
        #expect(fx.amountAed == Decimal(string: "45.32")!)
        #expect(fx.fxRate == Decimal(string: "3.6725")!)
        #expect(fx.originalAmountLabel == "USD 12.34")
        #expect(fx.amountLabel == "AED 45.32")
        #expect(fx.badge == .both)
        #expect(fx.cardLabel == "FAB •1234")
        #expect(fx.title == "Amazon")
        let refund = rows[1]
        #expect(MoneyFormat.plain(refund.amountOriginal) == "1234567.89")
        #expect(refund.amountLabel == "+ ≈ AED 1,234,567.89")
        #expect(refund.badge == .sms)
        #expect(refund.title == "NOON REFUND")
        #expect(refund.txnAt == nil)
    }

    @Test("statement_cycles with recon checks become chips")
    func cycles() throws {
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        let c = cycles[0]
        #expect(c.utilisation == Decimal(string: "0.1404")!)
        #expect(c.reconChecks?.sumDebits == Decimal(string: "5120.10")!)
        #expect(c.chips.map(\.label) == ["Check", "2 SMS not on statement", "SMS 88%"])
        #expect(c.periodLabel == "26 Aug – 25 Sep")
        #expect(cycles[1].chips.map(\.label) == ["Not reconciled"])
        #expect(cycles[1].kindLabel == "History extract")
        #expect(c.due(isLatest: true, today: CalendarDay(iso: "2026-10-15")!)?.text == "Due in 5 days")
        #expect(c.due(isLatest: true, today: CalendarDay(iso: "2026-11-02")!)?.text == "Was due 20 Oct")
        #expect(cycles[1].due(isLatest: false) == nil)
    }

    @Test("statement_cycles: an SMS statement is labelled and flags a missing history export")
    func smsCycle() throws {
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: Data(#"""
            [{"stmt_code": "stm_01hzy3k8w9m2n4p6q8r0s2t4v9", "account_code": "acc_01hzy3k8w9m2n4p6q8r0s2t4v7",
              "bank_code": "SIB", "card_last4": "5052", "kind": "statement", "statement_date": "2026-10-12",
              "period_start": "2026-09-13", "period_end": "2026-10-12", "due_date": "2026-10-30",
              "closing_balance": 4396.67, "min_due": 219.83, "credit_limit": 10000, "utilisation": 0.4397,
              "line_count": 0, "debits": 0, "credits": 0, "recon_status": "warn",
              "recon_checks": {"source": "sms", "history_uploaded": false, "opening_basis": "statement",
                               "expected_closing": "4335.82", "ledger_gap": "60.85", "balance_equation": false},
              "doc_code": null, "from_sms": true}]
            """#.utf8))
        let c = cycles[0]
        #expect(c.kindLabel == "SMS statement")
        #expect(c.rowSubtitle == "13 Sep – 12 Oct · from SMS")
        #expect(c.chips.map(\.label) == ["Check", "Balance off", "No history export"])
        let plain = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        #expect(plain[0].rowSubtitle == "26 Aug – 25 Sep")
        #expect(plain[1].rowSubtitle == "History extract · 1 Sep")
    }

    @Test("ingest_sms results")
    func ingest() throws {
        let results = try LedgerJSON.decode([SMSIngestResult].self, from: try fixture("ingest_sms"))
        #expect(results.map(\.status) == ["new", "rejected_otp", "duplicate_delivery", "invalid"])
        #expect(results.map(\.isFailure) == [false, false, false, true])
        #expect(results[3].failureReason == "Ledger rejected this message: received_at is not a timestamp")
        #expect(results[1].smsCode == nil)
        #expect(results[0].txnCode == "txn_01hzy3k8w9m2n4p6q8r0s2t4v6")
    }

    @Test("accounts take utilisation from the overview RPC (accounts[].utilisation)")
    func accountSummary() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let today = CalendarDay(iso: "2026-10-17")!
        let fab = AccountSummary(account: o.accounts[0])
        #expect(fab.utilisation == Decimal(string: "0.1404")!)
        #expect(fab.utilisationLabel == "14% used")
        #expect(fab.utilisationTone == .positive)
        #expect(fab.due(today: today)?.text == "Due in 3 days")
        #expect(fab.due(today: today)?.tone == .warn)
        // Past the due date: payment isn't detected on the phone, so never "Overdue".
        let later = fab.due(today: CalendarDay(iso: "2026-11-02")!)
        #expect(later?.text == "Was due 20 Oct")
        #expect(later?.tone == .neutral)
        let adcb = AccountSummary(account: o.accounts[1])
        #expect(adcb.utilisation == nil)
        #expect(adcb.due(today: today) == nil)
    }

    @Test("overview carries the server's change fractions; null bases decode as nil")
    func overviewChanges() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        #expect(o.changeVsPrevMonthToDate == Decimal(string: "-0.1805")!)
        #expect(o.changeVsAvg3m == nil)
        let old = try LedgerJSON.decode(Overview.self, from: try fixture("overview_legacy"))
        #expect(old.changeVsPrevMonthToDate == nil)
        #expect(old.accounts.first?.utilisation == nil)
    }

    /// The top-level keys `rpc('overview')` returned from the local stack on
    /// 2026-10-13 (demo ledger); the fixture carries every one of them.
    static let liveOverviewKeys: Set<String> = [
        "accounts", "change_vs_avg_3m", "change_vs_prev_month_to_date", "last_sms_at", "month", "open_reviews",
        "outstanding", "outstanding_complete", "outstanding_has_estimate", "payments", "pending_amount",
        "pending_count", "pending_unpriced_count", "projected_month_end", "recent", "spend", "spend_avg_3m",
        "spend_avg_3m_to_date", "spend_prev_month", "spend_prev_month_to_date", "top_categories",
        "uncategorized_count",
    ]

    @Test("overview keys are named as the wire spells them, with or without the snake-case strategy (X-33r)")
    func overviewWireKeys() throws {
        let data = try fixture("overview")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Self.liveOverviewKeys)

        let o = try LedgerJSON.decode(Overview.self, from: data)
        #expect(o.spendAvg3m == Decimal(string: "9000.33")!)
        #expect(o.spendAvg3mToDate == Decimal(string: "2650.4")!)
        #expect(o.projectedMonthEnd == Decimal(string: "9100.25")!)

        // The same document through a decoder with no key strategy: every
        // top-level figure lands identically, so no field rests on how
        // `.convertFromSnakeCase` capitalises `3m`. (Nested rows still use the
        // shared decoder's strategy, so they're emptied here.)
        var flat = object
        flat["top_categories"] = []
        flat["accounts"] = []
        flat["recent"] = []
        flat["last_sms_at"] = NSNull()
        let plain = try JSONDecoder().decode(Overview.self, from: JSONSerialization.data(withJSONObject: flat))
        #expect(plain.spendAvg3m == o.spendAvg3m && plain.spendAvg3mToDate == o.spendAvg3mToDate)
        #expect(plain.projectedMonthEnd == o.projectedMonthEnd && plain.changeVsAvg3m == o.changeVsAvg3m)
        #expect(plain.changeVsPrevMonthToDate == o.changeVsPrevMonthToDate)
        #expect(plain.spendPrevMonthToDate == o.spendPrevMonthToDate && plain.payments == o.payments)
        #expect(plain.outstanding == o.outstanding && plain.uncategorizedCount == o.uncategorizedCount)

        // A future month has no projection; an older server sends neither field.
        flat["projected_month_end"] = NSNull()
        let future = try JSONDecoder().decode(Overview.self, from: JSONSerialization.data(withJSONObject: flat))
        #expect(future.projectedMonthEnd == nil)
        let old = try LedgerJSON.decode(Overview.self, from: try fixture("overview_legacy"))
        #expect(old.spendAvg3m == Decimal(string: "9000.33")! && old.spendAvg3mToDate == nil && old.projectedMonthEnd == nil)
    }

    @Test("a missing required overview figure fails loudly, naming the wire key")
    func overviewMissingKey() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("overview")) as? [String: Any])
        object["spend_avg_3m"] = nil
        do {
            _ = try LedgerJSON.decode(Overview.self, from: JSONSerialization.data(withJSONObject: object))
            Issue.record("decoded without spend_avg_3m")
        } catch DecodingError.keyNotFound(let key, _) {
            #expect(key.stringValue == "spend_avg_3m")
        }
    }
}

@Suite("Presentation and query encoding")
struct PresentationTests {
    @Test("the hero words the server's ratio; it never computes one")
    func spendComparison() {
        let below = SpendComparison.versusSameDayLastMonth(change: Decimal(string: "-0.2")!, spend: 800, previous: 1000)
        #expect(below?.text == "20% below the same day last month")
        #expect(below?.tone == .positive)
        let above = SpendComparison.versusSameDayLastMonth(change: Decimal(string: "0.5")!, spend: 1500, previous: 1000)
        #expect(above?.text == "50% above the same day last month")
        #expect(above?.tone == .warn)
        #expect(SpendComparison.versusSameDayLastMonth(change: Decimal(string: "0.001")!, spend: 1, previous: 1)?.text
                == "Level with the same day last month")
        // Null ratio: last month's base was 0.
        #expect(SpendComparison.versusSameDayLastMonth(change: nil, spend: 10, previous: 0)?.text
                == "Nothing spent by this day last month")
        #expect(SpendComparison.versusSameDayLastMonth(change: nil, spend: 0, previous: 0) == nil)
        #expect(SpendComparison.versusAverage(change: Decimal(string: "-0.2")!)?.text == "20% below your 3-month average")
        #expect(SpendComparison.versusAverage(change: nil) == nil)
    }

    @Test("current month compares with the same day last month, a past month with the 3-month average")
    func overviewComparison() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let october = CalendarDay(iso: "2026-10-08")!
        #expect(o.comparison(today: october)?.text == "18% below the same day last month")
        #expect(o.heroEyebrow(today: october) == "October 2026 · so far")
        // The current month: last month by today is a pace-rule pin, not a line here.
        #expect(o.referenceLines(today: october) == ["3-month average AED 9,000 a month"])
        // A completed month is set against the whole previous month.
        #expect(o.referenceLines(today: CalendarDay(iso: "2026-11-02")!)
                == ["September AED 8,450", "3-month average AED 9,000 a month"])
        #expect(o.referenceLines(today: CalendarDay(iso: "2027-01-02")!).first == "September 2026 AED 8,450")
        #expect(o.showsLiveSections(today: october) && !o.showsLiveSections(today: CalendarDay(iso: "2026-11-02")!))
        #expect(o.scopeLabel(today: CalendarDay(iso: "2026-11-02")!) == "October 2026")
        #expect(o.emptyCategoriesMessage(today: CalendarDay(iso: "2026-11-02")!) == "No spending in October.")
        // Viewed in November, October is complete: its avg ratio is null in the fixture → no chip.
        #expect(o.comparison(today: CalendarDay(iso: "2026-11-02")!) == nil)
        #expect(o.heroEyebrow(today: CalendarDay(iso: "2026-11-02")!) == "October 2026")
    }

    @Test("VoiceOver reads the hero as one sentence, not \"AED\" and a number")
    func heroAccessibilityLabel() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        #expect(o.heroAccessibilityLabel(today: CalendarDay(iso: "2026-10-08")!)
                == "October spend so far, 1,234,568 dirhams")
        #expect(o.heroAccessibilityLabel(today: CalendarDay(iso: "2026-11-02")!) == "October spend, 1,234,568 dirhams")
        #expect(o.heroAccessibilityLabel(today: CalendarDay(iso: "2027-01-02")!) == "October 2026 spend, 1,234,568 dirhams")
    }

    @Test("Needs attention lists open reviews first, then uncategorised")
    func attention() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let october = CalendarDay(iso: "2026-10-08")!
        #expect(o.attention(today: october).map(\.kind) == [.reviews, .uncategorized])
        #expect(o.attention(today: october)[0].title == "1 item to review")
        #expect(o.attention(today: october)[1].title == "3 uncategorised this month")
        // Looking back at October from later on: the count is October's.
        #expect(o.attention(today: CalendarDay(iso: "2026-11-02")!)[1].title == "3 uncategorised in October")
        #expect(o.attention(today: CalendarDay(iso: "2027-01-02")!)[1].title == "3 uncategorised in October 2026")
    }

    @Test("due dates: one rule for Overview and Statements")
    func dueStatus() {
        let today = CalendarDay(iso: "2026-10-08")!
        let past = CalendarDay(iso: "2026-09-25")!
        #expect(DueStatus.describe(due: nil, isLatest: true, today: today) == nil)
        #expect(DueStatus.describe(due: today.adding(days: 3), isLatest: true, today: today)! == ("Due in 3 days", .warn))
        #expect(DueStatus.describe(due: today.adding(days: 12), isLatest: false, today: today)! == ("Due in 12 days", .neutral))
        // Payment detection unavailable (nil): never overdue.
        #expect(DueStatus.describe(due: past, isLatest: true, today: today)! == ("Was due 25 Sep", .neutral))
        // Superseded by a newer statement: never overdue, even with no payment.
        #expect(DueStatus.describe(due: past, isLatest: false, paymentDetected: false, today: today)! == ("Was due 25 Sep", .neutral))
        #expect(DueStatus.describe(due: past, isLatest: true, paymentDetected: true, today: today)! == ("Was due 25 Sep", .neutral))
        // Only the latest statement, past due, with no payment detected.
        #expect(DueStatus.describe(due: past, isLatest: true, paymentDetected: false, today: today)! == ("Overdue by 13 days", .danger))
    }

    @Test("Statements knows which cycle is each account's latest statement")
    func latestStatements() throws {
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        let content = StatementsModel.Content(cycles: cycles, documents: [])
        #expect(content.latestStatementCodes == [cycles[0].stmtCode])
    }

    @Test("search is safe inside PostgREST's or=()")
    func searchEncoding() {
        var q = ActivityQuery()
        #expect(q.searchOrFilter == nil)
        q.search = "  carrefour  "
        #expect(q.searchOrFilter == "description.ilike.*carrefour*,merchant_name.ilike.*carrefour*")
        q.search = "a,b(c)*d%e_f"
        #expect(q.searchOrFilter == #"description.ilike.*a_b_c__d\%e\_f*,merchant_name.ilike.*a_b_c__d\%e\_f*"#)
    }

    @Test func paging() {
        let request = PageRequest(offset: 200, limit: ActivityQuery.defaultPageSize)
        #expect(request.limit == 100)
        #expect(request.offset == 200 && request.lastIndex == 299)
        #expect(ActivityQuery.pageSizeOptions == [100, 200, 500, 1000, 2000])
        #expect(Paginator<LedgerTransaction>.defaultPageSize == 100)
    }

    @Test("activity rows group by business date, newest first, keeping server order")
    func sections() throws {
        let rows = try LedgerJSON.decode([LedgerTransaction].self, from: try fixture("transactions"))
        let sections = ActivityModel.sections(rows, today: CalendarDay(iso: "2026-10-08")!)
        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(Paginator<LedgerTransaction>.merge(rows, rows).count == 2)
    }

    @Test func evidenceBadges() {
        // An SMS or payment charge no statement has matched yet reads "SMS", never "Pending".
        #expect(EvidenceBadge.of(status: "pending", hasSms: true, hasStatement: false) == .sms)
        #expect(EvidenceBadge.of(status: "pending", hasSms: true, hasStatement: false).tone == .info)
        #expect(!EvidenceBadge.allCases.map(\.label).contains("Pending"))
        #expect(EvidenceBadge.of(status: "posted", hasSms: true, hasStatement: true) == .both)
        #expect(EvidenceBadge.of(status: "posted", hasSms: false, hasStatement: true) == .statement)
        #expect(EvidenceBadge.of(status: "orphaned", hasSms: true, hasStatement: false) == .orphaned)
    }

    @Test("profile keys satisfy ^[a-z0-9_-]{2,40}$")
    func profileKey() {
        #expect(ProfileStore.key(for: "Hussain's Cards", suffix: "ab12cd") == "hussain-s-cards-ab12cd")
        #expect(ProfileStore.key(for: "دبي", suffix: "ab12cd") == "ledger-ab12cd")
        let long = ProfileStore.key(for: String(repeating: "x", count: 80), suffix: "ab12cd")
        #expect(long.count <= 40)
        #expect(long.range(of: "^[a-z0-9_-]{2,40}$", options: .regularExpression) != nil)
    }

    @Test func selection() {
        let a = LedgerProfile(profileCode: "prf_a", key: "a", name: "A")
        let b = LedgerProfile(profileCode: "prf_b", key: "b", name: "B")
        #expect(ProfileStore.resolveSelection(stored: "prf_b", profiles: [a, b]) == "prf_b")
        #expect(ProfileStore.resolveSelection(stored: "prf_gone", profiles: [a, b]) == nil)
        #expect(ProfileStore.resolveSelection(stored: nil, profiles: [a]) == "prf_a")
    }

    @Test("Info.plist config refuses a secret key")
    func configRejectsSecretKey() {
        #expect(throws: LedgerConfig.ConfigError.self) {
            try LedgerConfig.load(info: [
                "LedgerSupabaseURL": "http://127.0.0.1:54321", "LedgerSupabasePublishableKey": "sb_secret_x",
                "LedgerAppGroup": "group.com.hussu97.ledger",
            ])
        }
    }

    @Test("Info.plist config: xcconfig blanks are treated as missing")
    func config() throws {
        let c = try LedgerConfig.load(info: [
            "LedgerSupabaseURL": "http://127.0.0.1:54321", "LedgerSupabasePublishableKey": "sb_publishable_test",
            "LedgerAppGroup": "group.com.hussu97.ledger", "LedgerKeychainGroup": ".com.hussu97.ledger.shared",
            "LedgerSentryDSN": "", "LedgerEnvironment": "$(LEDGER_ENVIRONMENT)",
        ])
        #expect(c.functionsURL.absoluteString == "http://127.0.0.1:54321/functions/v1")
        #expect(c.sentryDSN == nil)
        #expect(c.environment == "local")
        #expect(c.keychainGroup == "com.hussu97.ledger.shared")
        #expect(throws: LedgerConfig.ConfigError.self) { try LedgerConfig.load(info: [:]) }
    }

    @Test func settingsFlushMessages() {
        #expect(SettingsModel.describe(FlushReport()) == "Nothing to send.")
        #expect(SettingsModel.describe(FlushReport(sent: 3)) == "Sent 3 messages.")
        #expect(SettingsModel.describe(FlushReport(sent: 0, failed: 2, error: .network("x"))) == "Couldn't send: No connection to Ledger.")
    }
}
