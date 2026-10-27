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
        #expect(p.series.map(\.estimated) == [true, true, false, false])
        #expect(p.series[0].cash == nil && p.series[3].positions == dec("59000.00"))
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

    @Test("the header: value in USD and AED, the prices' date, and the stat tiles")
    func header() throws {
        let view = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now)
        #expect(view.title == "Swissquote portfolio")
        #expect(view.totalText == "USD 60,000.00")
        #expect(view.totalAedText == "≈ AED 220,350.00")
        #expect(view.asOfText == "Prices as of 27 Oct")
        #expect(view.stats.map(\.label) == ["Net deposits", "Profit", "Income", "Fees", "Cash", "In positions"])
        #expect(view.stats[1].value == "+USD 10,000.00" && view.stats[1].tone == .positive)
        #expect(view.stats[5].sub == "4 positions")
    }

    @Test("sync: fresh, late, failed with the last good sync, never")
    func sync() throws {
        let p = try Self.portfolio()
        let fresh = BrokerPortfolioPresentation(p, now: Self.now).sync
        #expect(fresh.text == "Synced with Swissquote today, 14:00" && fresh.tone == .neutral && fresh.detail == nil)

        let late = BrokerPortfolioPresentation(p, now: at("2026-10-30T08:00:00+00:00")).sync
        #expect(late.text == "Synced with Swissquote 3 days ago" && late.tone == .warn)

        var json = try #require(try JSONSerialization.jsonObject(with: fixture("broker_portfolio")) as? [String: Any])
        json["sync"] = ["status": "error", "error": "login refused", "last_synced_at": "2026-10-26T10:00:00+00:00",
                        "last_attempt_at": "2026-10-27T10:00:00+00:00"]
        let failed = BrokerPortfolioPresentation(
            try #require(try BrokerPortfolio.decode(JSONSerialization.data(withJSONObject: json))), now: Self.now).sync
        #expect(failed.text == "Last sync failed" && failed.tone == .danger)
        #expect(failed.detail == "login refused · Last good sync yesterday, 14:00")
    }

    @Test("positions: largest first, unpriced last; a note sells today next to if called, and opens")
    func positions() throws {
        let rows = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).positions
        #expect(rows.map(\.title) == ["NOTE WITHOUT TERMS 2031", "Bank Phoenix AAA/BBB 2029", "EXAMPLE ORD", "Unpriced thing"])

        let plain = rows[0]
        #expect(plain.holdingText == "30,000 nominal at 100%")
        #expect(plain.profitText == "+USD 2,000.00 (+6.67%)" && plain.profitTone == .positive)
        #expect(plain.incomeText == "USD 2,000.00 paid so far")
        #expect(plain.exits.isEmpty && !plain.opensNote)   // a note without terms has no scenarios

        let note = rows[1]
        #expect(note.opensNote && note.chips.isEmpty)
        #expect(note.profitText == "−USD 1,000.00 (−5%)" && note.profitTone == .danger)
        #expect(note.exits.map(\.title) == ["Sell today", "If called 26 Nov"])
        #expect(note.exits[0].totalText == "USD 19,000.00" && note.exits[0].detail == "−5% · bid 90%")
        #expect(note.exits[1].profitText == "+USD 1,500.00" && note.exits[1].detail == "+7.5% · 12% a year")

        #expect(rows[2].holdingText == "40 × USD 250.00" && rows[2].caption == "EXMP · US0000000001")
        #expect(rows[3].valueText == "No price" && rows[3].profitText == nil && rows[3].holdingText == "1.5 units")
    }

    @Test("ended positions: latest first, in, back and income, the result; a note opens")
    func closed() throws {
        let rows = BrokerPortfolioPresentation(try Self.portfolio(), now: Self.now).closed
        #expect(rows.map(\.title) == ["Bank Athena CCC 2028", "SOLD ORD"])
        #expect(rows[0].status == "Called early" && rows[0].statusTone == .positive && rows[0].opensNote)
        #expect(rows[0].flows == "USD 10,000.00 in · USD 11,000.00 back · USD 500.00 income")
        #expect(rows[0].returnText == "+15% · 20% a year" && rows[0].profitText == "+USD 1,500.00")
        #expect(rows[0].dates == "1 Dec 2025 – 1 Sep 2026")
        #expect(rows[1].status == "Sold" && !rows[1].opensNote)
        #expect(rows[1].flows == "USD 5,000.00 in · USD 4,000.00 back")
        #expect(rows[1].returnText == "−20%" && rows[1].profitTone == .danger)
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

    @Test("quantities: whole numbers grouped, fractions kept")
    func quantity() {
        #expect(BrokerText.quantity(dec("25000")) == "25,000")
        #expect(BrokerText.quantity(dec("1.250")) == "1.25")
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

@Suite("Structured notes: sold today next to if called")
struct NoteExitTests {
    static func notes(market: Bool) throws -> [NoteSummary] {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_notes_summary")) as? [[String: Any]])
        let called: [String: Any] = [
            "obs_date": "2027-04-22", "pay_date": "2027-04-29", "trigger_pct": "105", "redemption_pct": "100",
            "redemption": "40000.00", "coupons": "2000.00", "total": "42000.00", "profit": "4750.00",
            "return_pct": "12.75", "annualised_pct": "25.00",
        ]
        for i in json.indices {
            json[i]["if_called_next"] = called
            if market { json[i]["market"] = ["price_pct": "90", "value": "36000.00", "as_of": "2026-10-27", "profit": "-1250.00"] }
        }
        return try LedgerJSON.decode([NoteSummary].self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("a live note with a mark shows both; without a mark, or once ended, neither")
    func exits() throws {
        let notes = try Self.notes(market: true)
        let live = notes[1]
        #expect(live.market?.value == dec("36000.00") && live.market?.pricePct == dec("90"))
        let exits = live.exits(today: day("2026-10-27"))
        #expect(exits.map(\.title) == ["Sell today", "If called 22 Apr 2027"])
        #expect(exits[0].profitText == "−USD 1,250.00" && exits[0].tone == .danger && exits[0].detail == "bid 90%")
        #expect(exits[1].detail == "+12.75% · 25% a year")
        #expect(exits[1].stat.sub == "USD 42,000.00 back · +12.75% · 25% a year")
        #expect(notes[2].isEnded && notes[2].exits().isEmpty)
        #expect(try Self.notes(market: false)[1].exits().isEmpty)
    }

    @Test("an older server without market or if_called_next still decodes")
    func older() throws {
        let notes = try NoteFixtures.summary()
        #expect(notes.allSatisfy { $0.market == nil && $0.ifCalledNext == nil })
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
        if case .loaded(let p) = model.brokerSection(bankCode: "SWQ") {
            #expect(p.totalText == "USD 60,000.00")
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
