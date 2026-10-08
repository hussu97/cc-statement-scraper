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
        #expect(o.topCategories[1].displayName == "Uncategorized")
        #expect(o.accounts[0].creditLimit == Decimal(string: "30000")!)
        #expect(o.accounts[0].cardsLabel == "•1234, •5678")
        #expect(o.accounts[0].latestStatement?.dueDate?.iso == "2026-10-20")
        #expect(o.accounts[1].latestStatement == nil)
        #expect(o.accounts[1].title == "ADCB")
        #expect(o.recent[0].amountLabel == "AED 45.10")
        #expect(o.recent[0].badge == .pending)
        #expect(o.pendingSummary == "2 pending · AED 145.30")
        #expect(o.heroAmount == "1,234,568")
        #expect(o.lastSMSLabel(today: CalendarDay(iso: "2026-10-08")!) == "Last SMS 09:12")
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
        #expect(refund.badge == .pending)
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
        #expect(c.dueText(today: CalendarDay(iso: "2026-10-15")!) == "Due in 5 days")
        #expect(c.dueText(today: CalendarDay(iso: "2026-11-02")!) == "Was due 20 Oct")
        #expect(cycles[1].dueText() == nil)
    }

    @Test("ingest_sms results")
    func ingest() throws {
        let results = try LedgerJSON.decode([SMSIngestResult].self, from: try fixture("ingest_sms"))
        #expect(results.map(\.status) == ["new", "rejected_otp", "duplicate_delivery"])
        #expect(results[1].smsCode == nil)
        #expect(results[0].txnCode == "txn_01hzy3k8w9m2n4p6q8r0s2t4v6")
    }

    @Test("accounts take utilisation from the server's statement_cycles")
    func accountSummary() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        let today = CalendarDay(iso: "2026-10-17")!
        let fab = AccountSummary(account: o.accounts[0], cycles: cycles)
        #expect(fab.utilisationLabel == "14% used")
        #expect(fab.utilisationTone == .positive)
        #expect(fab.dueLabel(today: today) == "Due in 3 days")
        #expect(fab.dueTone(today: today) == .warn)
        let adcb = AccountSummary(account: o.accounts[1], cycles: cycles)
        #expect(adcb.utilisation == nil)
        #expect(adcb.dueLabel(today: today) == nil)
    }
}

@Suite("Presentation and query encoding")
struct PresentationTests {
    @Test func spendComparison() {
        let below = SpendComparison.versusAverage(spend: 800, average: 1000)
        #expect(below.text == "20% below your 3-month average")
        #expect(below.tone == .positive)
        #expect(SpendComparison.versusAverage(spend: 1500, average: 1000).text == "50% above your 3-month average")
        #expect(SpendComparison.versusAverage(spend: 10, average: 0).text == "No 3-month history yet")
        #expect(SpendComparison.versusLastMonthToDate(spend: 1200, previous: 1000) == "AED 200 more than this time last month")
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
        var q = ActivityQuery()
        #expect(q.pageSize == 100)
        q.page = 2
        #expect(q.rangeStart == 200 && q.rangeEnd == 299)
        #expect(ActivityQuery.pageSizeOptions == [100, 200, 500, 1000, 2000])
    }

    @Test("activity rows group by business date, newest first, keeping server order")
    func sections() throws {
        let rows = try LedgerJSON.decode([LedgerTransaction].self, from: try fixture("transactions"))
        let sections = ActivityModel.sections(rows, today: CalendarDay(iso: "2026-10-08")!)
        #expect(sections.map(\.title) == ["Today", "Yesterday"])
        #expect(ActivityModel.merge(rows, rows).count == 2)
    }

    @Test func evidenceBadges() {
        #expect(EvidenceBadge.of(status: "pending", hasSms: true, hasStatement: false) == .pending)
        #expect(EvidenceBadge.of(status: "posted", hasSms: true, hasStatement: true) == .both)
        #expect(EvidenceBadge.of(status: "posted", hasSms: false, hasStatement: true) == .statement)
        #expect(EvidenceBadge.of(status: "orphaned", hasSms: true, hasStatement: false) == .orphaned)
    }

    @Test("profile keys satisfy ^[a-z0-9_-]{2,40}$")
    func profileKey() {
        #expect(ProfileStore.key(for: "Alice's Cards", suffix: "ab12cd") == "alice-s-cards-ab12cd")
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

    @Test("Info.plist config: xcconfig blanks are treated as missing")
    func config() throws {
        let c = try LedgerConfig.load(info: [
            "LedgerSupabaseURL": "http://127.0.0.1:54321", "LedgerSupabaseAnonKey": "anon",
            "LedgerAppGroup": "group.com.example.ledger", "LedgerKeychainGroup": ".com.example.ledger.shared",
            "LedgerSentryDSN": "", "LedgerEnvironment": "$(LEDGER_ENVIRONMENT)",
        ])
        #expect(c.functionsURL.absoluteString == "http://127.0.0.1:54321/functions/v1")
        #expect(c.sentryDSN == nil)
        #expect(c.environment == "local")
        #expect(c.keychainGroup == "com.example.ledger.shared")
        #expect(throws: LedgerConfig.ConfigError.self) { try LedgerConfig.load(info: [:]) }
    }

    @Test func settingsFlushMessages() {
        #expect(SettingsModel.describe(FlushReport()) == "Nothing to send.")
        #expect(SettingsModel.describe(FlushReport(sent: 3)) == "Sent 3 messages.")
        #expect(SettingsModel.describe(FlushReport(sent: 0, failed: 2, error: .network("x"))) == "Couldn't send: No connection to Ledger.")
    }
}
