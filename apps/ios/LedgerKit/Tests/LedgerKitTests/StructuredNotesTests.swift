import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

/// The notes' JSON, captured from `structured_notes_summary` / `structured_note_detail` on the
/// local stack (series trimmed).
enum NoteFixtures {
    static func summary() throws -> [NoteSummary] {
        try LedgerJSON.decode([NoteSummary].self, from: fixture("structured_notes_summary"))
    }
    static func detail(_ name: String = "structured_note_detail") throws -> NoteDetail {
        try LedgerJSON.decode(NoteDetail.self, from: fixture(name))
    }
}

@Suite("Structured notes: the wire and the words")
struct StructuredNotesTests {
    @Test("the summary decodes every note, decimals exactly, statuses and groups as the web shows them")
    func summary() throws {
        let notes = try NoteFixtures.summary()
        #expect(notes.map(\.noteStatus) == [.live, .live, .autocalled])
        let notem = notes[1]
        #expect(notem.invested == dec("37250.00"))
        #expect(notem.worstNow?.pct == dec("87.0496"))
        #expect(notem.next?.days == 30)
        #expect(notem.next?.coupon?.wouldPay == false)
        #expect(notem.verdict == nil)   // captured before verdicts: an older server still decodes
        // A short list shows live notes only; without a broker mark, what was paid.
        let rows = NoteListRow.rows(notes, today: day("2026-10-27"))
        #expect(rows.map(\.title) == ["Example Bank B Athena AMZN/META 2031", "Example Bank M Phoenix AMZN/MSFT/GOOGL"])
        #expect(rows[1].valueLabel == "Paid" && rows[1].valueText == "USD 37,250" && rows[1].verdict == nil)
        #expect(NoteListRow.rows(notes, fundingAccount: "acc_other").isEmpty)
    }

    @Test("a row words the verdict and shows what the note is worth today")
    func listRow() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_notes_summary")) as? [[String: Any]])
        json[1]["verdict"] = ["kind": "coupon_at_risk", "symbol": "AMZN", "gap_pct": "12.58", "date": "2026-11-26",
                              "call_gap_pct": "20.62", "call_date": "2027-04-22"]
        json[1]["market"] = ["price_pct": "60", "value": "30000.00", "as_of": "2026-10-27", "profit": "-7250.00"]
        let notes = try LedgerJSON.decode([NoteSummary].self, from: JSONSerialization.data(withJSONObject: json))
        let row = NoteListRow(notes[1], today: day("2026-10-27"))
        #expect(row.verdict == "Coupon at risk: AMZN is 12.6% below the barrier (check 26 Nov)")
        #expect(row.verdictTone == .warn)
        #expect(row.valueLabel == "Worth today" && row.valueText == "USD 30,000")
        #expect(row.accessibilityLabel.hasSuffix("Worth today USD 30,000"))
    }

    @Test("the detail decodes in full: terms, schedule, payout, shares, levels, scenarios, outcomes, series")
    func detail() throws {
        let n = try NoteFixtures.detail()
        #expect(n.summary.name == "Example Bank M Phoenix AMZN/MSFT/GOOGL")
        #expect(n.terms.issuePricePct == dec("74.5"))
        #expect(n.observations.count == 9)
        #expect(n.payout.map(\.settlement) == ["cash", "physical"])
        #expect(n.underlyings.first { $0.isWorst }?.symbol == "AMZN")
        #expect(n.levels?.count == 4)
        #expect(n.scenarios?.best.when == "autocall")
        #expect(n.seriesLines.map(\.symbol) == ["AMZN", "MSFT", "GOOGL"])
        #expect(n.seriesLines[0].points.first?.pct == dec("100.00"))
        let ended = try NoteFixtures.detail("structured_note_detail_ended")
        #expect(ended.isEnded && ended.levels == nil && ended.scenarios == nil)
    }

    @Test("percentages, distances and level labels, worded like lib/notes.ts")
    func wording() {
        #expect(NoteText.pct(dec("98.00")) == "98%")
        #expect(NoteText.pct(dec("-24.5")) == "−24.5%")
        #expect(NoteText.pct(nil) == "—")
        #expect(NoteText.pct(dec("91.4655"), digits: 2) == "91.47%")
        #expect(NoteText.pct(dec("100.0000"), digits: 2) == "100%")
        #expect(NoteText.distance(dec("7.46")) == "needs +7.46%")
        #expect(NoteText.distance(dec("-6.67")) == "6.67% above")
        #expect(NoteText.distance(0) == "at the level")
        #expect(NoteText.distanceMet(dec("-0.3")) && !NoteText.distanceMet(dec("0.3")))
        #expect(NoteText.levelLabel(kind: "final", payoutPct: 100, settlement: "cash") == "At maturity ≥ this: 100%")
        #expect(NoteText.levelLabel(kind: "coupon") == "Coupon barrier")
        #expect(NoteText.signed(dec("-5975.22"), currency: "USD") == "−USD 5,975.22")
        #expect(NoteText.signed(0, currency: "USD") == "USD 0.00")
    }

    @Test("payout formulas and rows, highest first")
    func payout() {
        #expect(NoteText.branchFormula(interceptPct: 100, slope: 0) == "100%")
        #expect(NoteText.branchFormula(interceptPct: dec("-24.5"), slope: 1) == "WP − 24.5%")
        #expect(NoteText.branchFormula(interceptPct: 0, slope: dec("1.66666667")) == "1.667 × WP")
        let rows = NoteText.payoutRows([
            NotePayoutBranch(minWorstPct: 0, interceptPct: 0, slope: 1),
            NotePayoutBranch(minWorstPct: 100, interceptPct: 181, slope: 0),
            NotePayoutBranch(minWorstPct: dec("63.5"), interceptPct: 100, slope: 0),
        ])
        #expect(rows.map(\.when) == ["Worst ≥ 100%", "Worst 63.5% to 100%", "Worst below 63.5%"])
        #expect(rows.map(\.pays) == ["181%", "100%", "WP"])
    }

    @Test("the schedule in one line")
    func schedule() throws {
        let entries = [
            NoteText.ScheduleEntry(obsDate: day("2026-11-23"), couponRatePct: dec("0.667"), couponBarrierPct: 98, couponMemory: true,
                                   autocallTriggerPct: nil),
            NoteText.ScheduleEntry(obsDate: day("2027-04-22"), couponRatePct: dec("0.667"), couponBarrierPct: 98, couponMemory: true,
                                   autocallTriggerPct: 105),
        ]
        #expect(NoteText.scheduleSummary(entries) == "2 coupons of 0.667% (98% barrier, memory) · 1 autocall date from 22 Apr 2027 at 105%")
        #expect(NoteText.scheduleSummary([]) == "No coupons or autocalls")
        let stepping = [105, 100].map {
            NoteText.ScheduleEntry(obsDate: day("2027-05-27"), couponRatePct: nil, couponBarrierPct: nil, couponMemory: false,
                                   autocallTriggerPct: Decimal($0))
        }
        #expect(NoteText.scheduleSummary(stepping) == "2 autocall dates from 27 May 2027 at 105% stepping to 100%")
    }

    @Test("the maturity table keeps every 10% and the branch levels")
    func maturityRows() throws {
        let curve = try (0...30).map { i in
            try LedgerJSON.decode(NoteDetail.MaturityPoint.self, from: Data(
                #"{"worst_pct":"\#(i * 5)","payout_pct":"0","amount":"0","settlement":"cash","profit":"0"}"#.utf8))
        }
        let rows = NoteText.maturityTableRows(curve, branches: [
            NotePayoutBranch(minWorstPct: dec("63.5"), interceptPct: 100, slope: 0),
            NotePayoutBranch(minWorstPct: 45, interceptPct: -45, slope: 1),
            NotePayoutBranch(minWorstPct: 0, interceptPct: 0, slope: 1),
        ]).map { MoneyFormat.plain($0.worstPct) }
        #expect(rows == ["0", "10", "20", "30", "40", "45", "50", "60", "70", "80", "90", "100", "110", "120", "130", "140", "150"])
    }

    @Test("the note screen's words: header, countdown, bars, money, scenarios, schedule and terms")
    func presentation() throws {
        let today = day("2026-10-27")
        let n = try NoteFixtures.detail()
        #expect(n.headerDetail == "Example Bank M Financial · XS0000000405")
        #expect(n.verdictHeadline(today: today) == nil && n.verdictTone == .neutral)   // an older server
        #expect(n.countdown(today: today)
            == ["Next check 26 Nov 2026 · in 30 days · called if every stock is at or above 105% of its start"])
        #expect(n.bars.map(\.symbol) == ["AMZN", "MSFT", "GOOGL"])
        #expect(n.moneyStats(today: today).map(\.label) == ["Paid", "Worth today"])
        #expect(n.moneyStats(today: today)[0].value == "USD 37,250")
        #expect(n.moneyStats(today: today)[1].value == "—" && n.moneyStats(today: today)[1].sub == "No broker price yet")
        #expect(n.scenarioStats.map(\.value) == ["+USD 19,086.50", "−USD 37,250.00", "USD 6,336.50", "99%"])
        #expect(n.maturityRows.first.map { MoneyFormat.plain($0.worstPct) } == "150")
        #expect(n.scheduleSummary.contains("autocall date"))
        #expect(n.sections.map(\.title) == ["All scenarios", "Full schedule", "Price history", "Terms"])
        let rows = n.scheduleRows
        #expect(rows[0].coupon == "0.667% if ≥ 98% (memory)")
        #expect(rows[0].outcomes.map(\.text) == ["Coupon missed · worst AMZN 93.11%"])
        #expect(rows[5].outcomes.count == 2)
        #expect(rows[6].pending == "to come")
        #expect(rows[6].autocall == "100% if ≥ 105%")
        #expect(n.termRows.first { $0.label == "Issuer" }?.value == "Example Bank M Financial")

        let ended = try NoteFixtures.detail("structured_note_detail_ended")
        #expect(ended.moneyStats(today: today).map(\.label) == ["Paid", "Got back", "Profit"])
        #expect(ended.moneyStats(today: today).map(\.value) == ["USD 5,000", "USD 5,100", "+USD 100"])
        #expect(ended.moneyStats(today: today)[2].sub == "+2%" && ended.moneyStats(today: today)[2].tone == .positive)
        #expect(!ended.sections.contains(.scenarios))
        #expect(ended.bars.isEmpty && ended.countdown(today: today).isEmpty && ended.verdictHeadline(today: today) == nil)
        #expect(ended.scheduleRows.flatMap(\.outcomes).contains { $0.text == "Called early USD 5,000.00 · worst GOOGL 103.95%" })
    }

    @Test("a note without prices yet (just synced) still decodes: the next check's would-pay is unknown")
    func awaitingPrices() throws {
        var notes = try #require(try JSONSerialization.jsonObject(with: fixture("structured_notes_summary")) as? [[String: Any]])
        var next = try #require(notes[1]["next"] as? [String: Any])
        var coupon = try #require(next["coupon"] as? [String: Any])
        var autocall = try #require(next["autocall"] as? [String: Any])
        coupon["would_pay"] = NSNull()
        autocall["would_call"] = NSNull()
        next["coupon"] = coupon
        next["autocall"] = autocall
        notes[1]["next"] = next
        notes[1]["worst_now"] = NSNull()
        notes[1]["if_ended_today"] = NSNull()
        notes[1]["verdict"] = ["kind": "awaiting_prices"]
        let decoded = try LedgerJSON.decode([NoteSummary].self, from: JSONSerialization.data(withJSONObject: notes))
        #expect(decoded[1].next?.coupon?.wouldPay == nil && decoded[1].next?.autocall?.wouldCall == nil)
    }

    @Test("a coupon at risk: the verdict, the coupon it pays and when the call comes; the money with if called")
    func couponAtRisk() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_note_detail")) as? [String: Any])
        json["verdict"] = ["kind": "coupon_at_risk", "symbol": "AMZN", "gap_pct": "12.58", "date": "2026-11-26",
                           "call_gap_pct": "20.62", "call_date": "2027-04-22"]
        json["market"] = ["price_pct": "60", "value": "30000.00", "as_of": "2026-10-27", "profit": "-7250.00"]
        json["if_called_next"] = [
            "obs_date": "2027-04-22", "pay_date": "2027-04-29", "trigger_pct": "105", "redemption_pct": "100",
            "redemption": "50000.00", "coupons": "2000.00", "total": "52000.00", "profit": "14750.00",
            "return_pct": "39.6", "annualised_pct": "81.4",
        ]
        let n = try LedgerJSON.decode(NoteDetail.self, from: JSONSerialization.data(withJSONObject: json))
        let today = day("2026-10-27")
        #expect(n.verdictHeadline(today: today) == "Coupon at risk: AMZN is 12.6% below the barrier (check 26 Nov)")
        #expect(n.verdictTone == .warn)
        #expect(n.countdown(today: today) == [
            "Next check 26 Nov 2026 · in 30 days · called if every stock is at or above 105% of its start",
            "Coupon of USD 2,334.50 is paid only if every stock is at or above 98% of its start",
            "Called on 22 Apr 2027 if AMZN rises 20.6%",
        ])
        let money = n.moneyStats(today: today)
        #expect(money.map(\.label) == ["Paid", "Worth today", "If called on 22 Apr 2027"])
        #expect(money[1].value == "USD 30,000" && money[1].sub == "−USD 7,250 if sold today")
        #expect(money[2].value == "USD 52,000" && money[2].sub == "+USD 14,750 · 81% a year" && money[2].tone == .positive)
    }
}
