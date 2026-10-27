import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private func at(_ iso: String) -> Date { LedgerDates.parseTimestamp(iso)! }

/// `broker_portfolio` (the Swissquote sync) on the account screen: the wire, tolerance of values
/// this build doesn't know, and the decisions the section makes. The fixture's numbers are
/// invented round figures in the RPC's real shape.
@Suite("Broker portfolio: the wire and the words")
struct BrokerPortfolioTests {
    static func portfolio() throws -> BrokerPortfolio {
        try #require(try BrokerPortfolio.decode(try fixture("broker_portfolio")))
    }

    /// 27 Oct 2026, 16:00 in Dubai.
    static let now = at("2026-10-27T12:00:00+00:00")

    @Test("the portfolio decodes in full, decimals exactly, unknown kinds tolerated")
    func decodes() throws {
        let p = try Self.portfolio()
        #expect(p.provider == "swissquote" && p.currency == "USD")
        #expect(p.total == dec("60000.00") && p.totalAed == dec("220350.00"))
        #expect(p.netDeposits == dec("50000.00") && p.profit == dec("10000.00"))
        #expect(p.sync.status == "ok" && p.sync.lastSyncedAt == at("2026-10-27T10:00:00+00:00"))
        #expect(p.asOf == day("2026-10-27"))
        #expect(p.positions.map(\.kind) == [.security, .structuredNote, .broker, .broker])   // "crypto_wrapper" → broker
        let note = try #require(p.positions[1].note)
        #expect(note.noteStatus == .live && note.next?.coupon?.wouldPay == true)
        #expect(note.ifCalledNext?.total == dec("21500.00") && note.ifCalledNext?.annualisedPct == dec("12.00"))
        #expect(p.positions[3].value == nil && p.positions[3].sellNow == nil && p.positions[3].quantity == dec("1.5"))
        #expect(p.closed.map(\.noteStatus) == [nil, "autocalled"])
        #expect(p.closedTotal?.count == 2 && p.closedTotal?.profit == dec("500.00"))
        #expect(note.verdict == NoteVerdict(kind: .needs, symbol: "AAA", gapPct: dec("10.50"), date: day("2026-11-26")))
        #expect(p.series.map(\.estimated) == [true, true, false, false])
        #expect(p.series[0].cash == nil && p.series[3].positions == dec("59000.00"))
    }

    @Test("a live note's stocks on bars: worst first, ticks at the call and the barrier, the dot coloured by where it is")
    func bars() throws {
        let p = try Self.portfolio()
        let bars = NoteStockBar.bars(try #require(p.positions[1].note?.underlyings))
        #expect(bars.map(\.symbol) == ["AAA", "BBB", "CCC"])
        let aaa = bars[0]
        #expect(aaa.isWorst && aaa.closeText == "90.50" && aaa.startText == "start 100.00")
        #expect(aaa.statusText == "needs +10.5%" && aaa.statusTone == .warn)
        #expect(aaa.barrierLabel == "barrier" && aaa.dotTone == .warn)
        // 70 (barrier) to 100 (call and start), padded 8% of the span each side: 67.6 to 102.4.
        #expect(abs(try #require(aaa.barrierAt) - 2.4 / 34.8) < 1e-9)
        #expect(abs(try #require(aaa.closeAt) - 22.9 / 34.8) < 1e-9)
        #expect(abs(try #require(aaa.callAt) - 32.4 / 34.8) < 1e-9)
        let bbb = bars[1]
        #expect(bbb.statusText == "at call level" && bbb.statusTone == .positive && bbb.dotTone == .positive)
        #expect(bbb.barrierAt == nil && bbb.barrierLabel == nil)
        let ccc = bars[2]
        #expect(ccc.statusText == "No price yet" && ccc.closeAt == nil && ccc.closeText == "—")
        #expect(aaa.accessibilityLabel == "AAA, 90.50, start 100.00, needs +10.5%")
    }

    @Test("no autocall left: the bar's words read break-even, the dot danger below it")
    func breakEvenBar() throws {
        let json = #"""
        {"symbol":"JPM","name":"JPMorgan","initial":"300","close":"250","is_worst":true,"perf_pct":"83.33",
         "to_autocall_pct":null,"to_coupon_pct":null,"to_break_even_pct":"4.2","autocall_level":null,
         "coupon_level":null,"break_even_level":"260.5"}
        """#
        let u = try LedgerJSON.decode(NoteDetail.Underlying.self, from: Data(json.utf8))
        let bar = NoteStockBar.bars([u])[0]
        #expect(bar.statusText == "needs +4.2%" && bar.statusTone == .danger)
        #expect(bar.barrierLabel == "break-even" && bar.dotTone == .danger && bar.callAt == nil)
    }

    @Test("null (an account with no sync) and an empty body read as no portfolio")
    func noSync() throws {
        #expect(try BrokerPortfolio.decode(Data("null".utf8)) == nil)
        #expect(try BrokerPortfolio.decode(Data(" null\n".utf8)) == nil)
        #expect(try BrokerPortfolio.decode(Data()) == nil)
    }

    @Test("an unknown provider, sync status or note status doesn't fail the response")
    func tolerant() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        json["provider"] = "interactive_brokers"
        json["sync"] = ["status": "paused", "last_synced_at": NSNull(), "last_attempt_at": NSNull(), "error": NSNull()]
        var positions = try #require(json["positions"] as? [[String: Any]])
        var note = try #require(positions[1]["note"] as? [String: Any])
        note["status"] = "knocked_out"
        positions[1]["note"] = note
        json["positions"] = positions
        let p = try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json)))
        let view = BrokerPortfolioPresentation(p, now: Self.now)
        #expect(view.providerName == "Interactive Brokers")
        #expect(view.sync.text == "Not synced yet")
        #expect(p.positions[1].note?.noteStatus == .live)
    }

    @Test("the header: three numbers, whole units, AED under the total")
    func header() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.providerName == "Swissquote")
        #expect(view.figures.map(\.label) == ["Total value", "Profit", "Cash"])
        #expect(view.figures.map(\.value) == ["USD 60,000", "+USD 10,000", "USD 1,000"])
        #expect(view.figures[0].sub == "≈ AED 220,350")
        #expect(view.figures[1].sub == "on USD 50,000 put in" && view.figures[1].tone == .positive)
    }

    @Test("sync: fresh, late, failed with the broker's error, never")
    func sync() throws {
        let p = try Self.portfolio()
        let fresh = BrokerPortfolioPresentation(p, now: Self.now).sync
        #expect(fresh.text == "Synced today, 14:00" && fresh.tone == .neutral && fresh.detail == nil)

        let late = BrokerPortfolioPresentation(p, now: at("2026-10-30T08:00:00+00:00")).sync
        #expect(late.text == "Synced 3 days ago" && late.tone == .warn)

        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        json["sync"] = ["status": "error", "error": "login refused", "last_synced_at": "2026-10-26T10:00:00+00:00",
                        "last_attempt_at": "2026-10-27T10:00:00+00:00"]
        let failed = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now).sync
        #expect(failed.text == "Last sync failed: login refused" && failed.tone == .warn)
        #expect(failed.detail == "Last good sync yesterday, 14:00")
    }

    @Test("tabs: Portfolio, Transactions, and Past notes with its count once something ended")
    func tabs() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.tabs.map(view.title) == ["Portfolio", "Transactions", "Past notes (2)"])
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        json["closed"] = []
        let none = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now)
        #expect(none.tabs == [.portfolio, .transactions])
    }

    @Test("Portfolio: a card per live note with its verdict and two numbers; everything else in one line")
    func portfolioTab() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        let cards = view.notes
        #expect(cards.map(\.title) == ["Bank Phoenix AAA/BBB 2029"])
        let card = cards[0]
        #expect(card.verdict == "Called on 26 Nov if AAA rises 10.5%" && card.verdictTone == .warn)
        #expect(card.figures.map(\.label) == ["Worth today", "If called on 26 Nov"])
        #expect(card.figures.map(\.value) == ["USD 18,000", "USD 21,500"])
        #expect(card.figures[1].sub == "+USD 1,500 · 12% a year" && card.figures[1].tone == .positive)
        #expect(card.bars.map(\.symbol) == ["AAA", "BBB", "CCC"])

        let others = view.otherHoldings
        #expect(others.map(\.title) == ["NOTE WITHOUT TERMS 2031", "EXAMPLE ORD", "Unpriced thing"])
        #expect(others[0].valueText == "USD 30,000" && others[0].profitText == "+USD 2,000 (+6.7%)")
        #expect(others[1].profitText == "+USD 2,000 (+25%)" && others[1].profitTone == .positive)
        #expect(others[2].valueText == "No price" && others[2].profitText == nil)
        #expect(others.allSatisfy { !$0.opensNote })
    }

    @Test("a live note without a call date left shows what was paid; an ended one leaves Portfolio")
    func noCallLeft() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        var positions = try #require(json["positions"] as? [[String: Any]])
        var note = try #require(positions[1]["note"] as? [String: Any])
        note["if_called_next"] = NSNull()
        positions[1]["note"] = note
        var ended = positions[1]
        ended["holding_code"] = "hld_01hhhhhhhhhhhhhhhhhhhhhhhh"
        var endedNote = note
        endedNote["status"] = "autocalled"
        ended["note"] = endedNote
        json["positions"] = positions + [ended]
        let view = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now)
        #expect(view.notes.count == 1)
        #expect(view.notes[0].figures.map(\.label) == ["Worth today", "Paid"])
        #expect(view.notes[0].figures[1].value == "USD 20,000")
        #expect(view.otherHoldings.first { $0.holdingCode == "hld_01hhhhhhhhhhhhhhhhhhhhhhhh" }?.opensNote == true)
    }

    @Test("Past notes: the total in one line, then each one held, its profit and return")
    func pastNotes() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.pastSummary == "2 ended · +USD 500 earned on USD 15,000")
        let rows = view.past
        #expect(rows.map(\.title) == ["Bank Athena CCC 2028", "SOLD ORD"])
        #expect(rows[0].heldText == "held Dec 2025–Sep 2026" && rows[0].profitText == "+USD 1,500")
        #expect(rows[0].returnText == "+15% · 20% a year" && rows[0].opensNote)
        #expect(rows[1].heldText == "held Jan–Jun 2025" && rows[1].profitTone == .danger && !rows[1].opensNote)
        #expect(BrokerPastRow.held(day("2026-03-01"), day("2026-03-20")) == "held Mar 2026")
        #expect(BrokerPastRow.held(nil, day("2026-03-20")) == "ended Mar 2026")

        // All called early: said so.
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        let closed = try #require(json["closed"] as? [[String: Any]])
        json["closed"] = [closed[1]]
        json["closed_total"] = ["count": "1", "invested": "10000.00", "received": "11500.00", "profit": "1500.00"]
        let called = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now)
        #expect(called.pastSummary == "1 called early · +USD 1,500 earned on USD 10,000")
        json["closed_total"] = NSNull()
        let older = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now)
        #expect(older.pastSummary == nil)
    }

    @Test("the chart: rebuilt days apart from synced ones, joined at the switch, never two runs as one line")
    func chart() throws {
        let chart = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).chart
        #expect(chart.showsChart && chart.hasEstimated)
        #expect(chart.values.map(\.run) == ["run-0", "run-0", "run-1", "run-1", "run-1"])
        #expect(chart.values[2].day == day("2026-10-24") && !chart.values[2].estimated)   // the joint
        #expect(chart.deposits.count == 4 && chart.deposits[0].value == dec("50000.00"))
        #expect(chart.note.contains("23 Oct 2026 to 24 Oct 2026"))
        #expect(chart.accessibilityValue == "27 Oct 2026: USD 60,000.00 against USD 50,000.00 put in")

        let back = BrokerValueChart([
            .init(asOf: day("2026-01-01"), total: 1, netDeposits: 1, estimated: true),
            .init(asOf: day("2026-01-02"), total: 2, netDeposits: 1, estimated: false),
            .init(asOf: day("2026-01-03"), total: 3, netDeposits: 1, estimated: true),
        ], currency: "USD")
        #expect(Set(back.values.map(\.run)).count == 3)
        #expect(!BrokerValueChart([], currency: "USD").showsChart)
        #expect(BrokerValueChart.axisLabel(day("2025-10-01")) == "Oct ’25")
    }

    @Test("the section shows only for a broker account until a portfolio arrives")
    func section() throws {
        let p = try Self.portfolio()
        #expect(BrokerSection(.loaded(p), bankCode: "FAB") != .hidden)
        #expect(BrokerSection(.loaded(nil), bankCode: "SWQ") == .hidden)
        #expect(BrokerSection(.loading(previous: nil), bankCode: "SWQ") == .loading)
        #expect(BrokerSection(.loading(previous: nil), bankCode: "FAB") == .hidden)
        #expect(BrokerSection(.failed("Offline", previous: nil), bankCode: "SWQ") == .failed("Offline"))
        #expect(BrokerSection(.failed("Offline", previous: nil), bankCode: nil) == .hidden)
        if case .loaded = BrokerSection(.failed("Offline", previous: .some(p)), bankCode: "SWQ") {} else {
            Issue.record("a refresh that fails keeps the portfolio on screen")
        }
    }

    @Test("a broker balance says where it came from")
    func balanceSource() {
        let balance = BankAccountBalance(accountCode: "acc_x", bankCode: "SWQ", kind: "current", nickname: nil, accountRef: nil,
                                         currency: "USD", balance: 1, balanceAed: nil, asOf: Self.now, anchorSource: "broker")
        #expect(balance.asOfText(now: Self.now)?.hasSuffix("· from the broker") == true)
    }

    @Test("a coupon paid before the note was bought is worded, and an unknown outcome is readable")
    func outcomeKinds() {
        #expect(NoteText.outcomeLabel("coupon_before_purchase") == "Coupon paid before you bought it")
        #expect(NoteText.outcomeTone("coupon_before_purchase") == .neutral)
        #expect(NoteText.outcomeLabel("partial_call") == "Partial Call")
    }
}

@Suite("Broker portfolio on the account screen")
@MainActor
struct BrokerPortfolioScreenTests {
    @Test("the account screen reads the portfolio once, again on refresh and after a failure")
    func loads() async throws {
        let api = StubAPI()
        api.accountLedgerFixture = try LedgerJSON.decode(AccountLedger.self, from: try fixture("account_ledger"))
        api.brokerPortfolioError = .network("-1009")
        let model = AccountLedgerModel(api: api, accountCode: "acc_x", today: { day("2026-10-27") })
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(model.brokerSection(bankCode: "SWQ") == .failed(LedgerAPIError.network("-1009").description))

        api.brokerPortfolioError = nil
        api.brokerPortfolioFixture = try BrokerPortfolioTests.portfolio()
        model.month.goBack()
        await model.loadIfNeeded(profileCode: "prf_a")   // another month: the failed portfolio is read again
        #expect(api.calls("brokerPortfolio") == 2)
        #expect(model.brokerHoldings.contains("hld_01cccccccccccccccccccccccc") && model.brokerHoldings.count == 6)
        if case .loaded(let p) = model.brokerSection(bankCode: "SWQ") {
            #expect(p.figures[0].value == "USD 60,000")
        } else {
            Issue.record("the portfolio should show")
        }

        model.month.goBack()
        await model.loadIfNeeded(profileCode: "prf_a")
        #expect(api.calls("brokerPortfolio") == 2)   // once loaded, a month switch doesn't re-read it
        await model.load(profileCode: "prf_a")
        #expect(api.calls("brokerPortfolio") == 3)   // pull to refresh does
    }
}
