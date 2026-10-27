import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private let today = day("2026-10-27")

/// A live note in one line (`verdict`): the server's kinds, worded as the redesign spells them.
@Suite("Structured notes: the verdict in words")
struct NoteVerdictTests {
    @Test("on track: called on its date, good news")
    func onTrack() {
        let v = NoteVerdict(kind: .onTrack, symbol: "META", gapPct: dec("-5.64"), date: day("2027-03-15"))
        #expect(v.headline(today: today) == "On track to be called on 15 Mar 2027")
        #expect(v.tone == .positive)
    }

    @Test("needs: the stock holding it back and the rise it needs; past 10% a warning")
    func needs() {
        let v = NoteVerdict(kind: .needs, symbol: "GOOGL", gapPct: dec("9.33"), date: day("2027-03-15"))
        #expect(v.headline(today: today) == "Called on 15 Mar 2027 if GOOGL rises 9.3%")
        #expect(v.tone == .neutral)
        let far = NoteVerdict(kind: .needs, symbol: "ORCL", gapPct: dec("38.88"), date: day("2026-12-22"))
        #expect(far.headline(today: today) == "Called on 22 Dec if ORCL rises 38.9%")
        #expect(far.tone == .warn)
    }

    @Test("coupon at risk: how far below the barrier, the check date, and the call after it")
    func couponAtRisk() {
        let v = NoteVerdict(kind: .couponAtRisk, symbol: "GOOGL", gapPct: dec("0.30"), date: day("2026-11-23"),
                            callGapPct: dec("7.46"), callDate: day("2027-04-22"))
        #expect(v.headline(today: today) == "Coupon at risk: GOOGL is 0.3% below the barrier (check 23 Nov)")
        #expect(v.tone == .warn)
        #expect(v.callLine(today: today) == "Called on 22 Apr 2027 if GOOGL rises 7.5%")
        #expect(NoteVerdict(kind: .needs, symbol: "X", gapPct: 1).callLine(today: today) == nil)
    }

    @Test("to maturity: capital safe above break-even, danger below it")
    func toMaturity() {
        let safe = NoteVerdict(kind: .toMaturity, symbol: "JPM", gapPct: dec("-9.60"), date: day("2028-06-20"))
        #expect(safe.headline(today: today) == "Runs to Jun 2028 · capital safe while JPM stays above its break-even")
        #expect(safe.tone == .neutral)
        let below = NoteVerdict(kind: .toMaturity, symbol: "JPM", gapPct: dec("4.2"), date: day("2028-06-20"))
        #expect(below.headline(today: today) == "Runs to Jun 2028 · JPM is 4.2% below break-even")
        #expect(below.tone == .danger)
    }

    @Test("waiting for prices, ended; an unknown kind decodes and says nothing")
    func others() throws {
        #expect(NoteVerdict(kind: .awaitingPrices).headline(today: today) == "Waiting for today's prices")
        #expect(NoteVerdict(kind: .ended).headline(today: today) == "Ended")
        let unknown = try LedgerJSON.decode(NoteVerdict.self, from: Data(#"{"kind":"knocked_in","symbol":"X"}"#.utf8))
        #expect(unknown.kind == .unknown("knocked_in"))
        #expect(unknown.headline(today: today) == nil && unknown.tone == .neutral)
        let wire = try LedgerJSON.decode(NoteVerdict.self, from: Data(
            #"{"kind":"coupon_at_risk","symbol":"GOOGL","gap_pct":"0.30","date":"2026-11-23","call_gap_pct":"7.46","call_date":"2027-04-22"}"#.utf8))
        #expect(wire.kind == .couponAtRisk && wire.callDate == day("2027-04-22") && wire.gapPct == dec("0.30"))
    }
}

/// Investments with a synced broker account: one row stands in for its holdings.
@Suite("Investments: broker accounts grouped")
struct BrokerAccountsTests {
    static func accounts() throws -> [BrokerAccountSummary] {
        try LedgerJSON.decode([BrokerAccountSummary].self, from: fixture("broker_accounts_summary"))
    }

    @Test("the summary decodes, counts from strings, unknown providers kept")
    func decodes() throws {
        let a = try Self.accounts()
        #expect(a.map(\.name) == ["Swissquote", "IBKR"])
        #expect(a[0].liveNotes == 1 && a[0].positions == 4 && a[0].total == dec("60000.00"))
        #expect(a[0].holdingCodes.count == 3 && a[0].lastSyncedAt != nil)
        #expect(a[1].provider == "interactive_brokers" && a[1].netDeposits == nil && a[1].syncStatus == "error")
    }

    @Test("a row per account: value, AED, profit and live notes; a failed sync said")
    func rows() throws {
        let rows = try Self.accounts().map(BrokerAccountRow.init)
        #expect(rows[0].title == "Swissquote" && rows[0].valueText == "USD 60,000" && rows[0].aedText == "≈ AED 220,350")
        #expect(rows[0].detail == "+USD 10,000 · 1 live note" && rows[0].profitTone == .positive && !rows[0].syncFailed)
        #expect(rows[1].aedText == nil && rows[1].detail == "−AED 120 · last sync failed" && rows[1].syncFailed)
    }

    @Test("the holdings an account shows leave Investments' own lists, and so do its notes")
    func layout() throws {
        let valuation = try LedgerJSON.decode(HoldingsValuation.self, from: try fixture("holdings_valuation_kinds"))
        let plain = InvestmentsLayout(valuation: valuation, brokerAccounts: [])
        #expect(plain.brokerRows.isEmpty && plain.groups.map(\.kind) == [.metal, .plan, .broker, .security, .deposit])

        let grouped = InvestmentsLayout(valuation: valuation, brokerAccounts: try Self.accounts())
        #expect(grouped.brokerRows.count == 2)
        #expect(grouped.groups.map(\.kind) == [.metal, .plan, .deposit])   // IBKR and Example Co are shown by the account
        #expect(!grouped.isEmpty)

        let notes = try NoteFixtures.summary()
        #expect(plain.notes(notes).count == 2)   // never the ended one
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_accounts_summary")) as? [[String: Any]])
        json[0]["holding_codes"] = ["hld_01k5ys7hj5wskbg45vcb5vtz79"]
        let holding = InvestmentsLayout(
            valuation: valuation,
            brokerAccounts: try LedgerJSON.decode([BrokerAccountSummary].self, from: JSONSerialization.data(withJSONObject: json)))
        #expect(holding.notes(notes).map(\.title) == ["Example Bank B Athena AMZN/META 2031"])
    }

    @Test("Investments reads the accounts with the valuation; a failed read lists every holding")
    @MainActor
    func model() async throws {
        let api = StubAPI()
        api.valuationFixture = try LedgerJSON.decode(HoldingsValuation.self, from: try fixture("holdings_valuation_kinds"))
        api.brokerAccountsFixture = try Self.accounts()
        let m = InvestmentsModel(api: api, today: { day("2026-10-27") })
        await m.load(profileCode: "prf_a")
        #expect(api.calls("brokerAccounts") == 1)
        #expect(m.state.value?.layout.groups.map(\.kind) == [.metal, .plan, .deposit])

        api.brokerAccountsError = .network("-1009")
        await m.load(profileCode: "prf_a")
        #expect(m.state.value?.brokerAccounts.isEmpty == true)
        #expect(m.state.value?.layout.groups.count == 5)
    }
}
