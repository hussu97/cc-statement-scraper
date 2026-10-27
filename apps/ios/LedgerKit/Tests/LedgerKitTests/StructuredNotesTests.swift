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
    static func extract() throws -> TermSheetExtract { try TermSheetExtract.decode(fixture("termsheet_extract")) }
}

@Suite("Structured notes: the wire and the words")
struct StructuredNotesTests {
    @Test("the summary decodes every note, decimals exactly, statuses and groups as the web shows them")
    func summary() throws {
        let notes = try NoteFixtures.summary()
        #expect(notes.map(\.noteStatus) == [.live, .live, .autocalled])
        let marex = notes[1]
        #expect(marex.invested == dec("37250.00"))
        #expect(marex.worstNow?.pct == dec("87.0496"))
        #expect(marex.next?.days == 30)
        #expect(marex.next?.coupon?.wouldPay == false)
        #expect(marex.rowDetail(today: day("2026-10-27")) == "AMZN · MSFT · GOOGL · worst AMZN at 87.05% · next 26 Nov")
        // An autocall date that wouldn't call says nothing, as on the web.
        #expect(marex.nextOutlook == nil)
        #expect(marex.rowResult.text == "invested")
        let ended = notes[2]
        #expect(ended.rowDetail() == "GOOGL · ended 21 Jun 2026")
        #expect(ended.rowResult.text == "+USD 100.00 (2%)")
        #expect(ended.rowResult.tone == .positive)
        let groups = NoteGroups(notes)
        #expect(groups.live.count == 2 && groups.ended.count == 1)
        #expect(NoteGroups(notes, fundingAccount: "acc_other").isEmpty)
    }

    @Test("a coupon-only next date reads on track or at risk")
    func couponOutlook() throws {
        var json = try JSONSerialization.jsonObject(with: fixture("structured_notes_summary")) as! [[String: Any]]
        var next = json[1]["next"] as! [String: Any]
        next["autocall"] = NSNull()
        json[1]["next"] = next
        let notes = try LedgerJSON.decode([NoteSummary].self, from: JSONSerialization.data(withJSONObject: json))
        #expect(notes[1].nextOutlook?.text == "Coupon at risk")
        #expect(notes[1].nextOutlook?.tone == .warn)
    }

    @Test("the detail decodes in full: terms, schedule, payout, shares, levels, scenarios, outcomes, series")
    func detail() throws {
        let n = try NoteFixtures.detail()
        #expect(n.summary.name == "Marex Phoenix AMZN/MSFT/GOOGL")
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
        #expect(try NoteFixtures.extract().draft.scheduleSummary == "2 autocall dates from 27 May 2027 at 105% stepping to 100%")
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

    @Test("the note screen's words: stats, outlooks, levels, scenarios, schedule and terms")
    func presentation() throws {
        let n = try NoteFixtures.detail()
        #expect(n.summaryStats.map(\.label) == ["Invested", "Received", "If it ended today", "Break-even at maturity"])
        #expect(n.summaryStats[0].sub == "USD 50,000.00 nominal at 74.5% · 5 May 2026")
        #expect(n.summaryStats[2].value == "−USD 5,975.22")
        #expect(n.summaryStats[2].tone == .danger)
        #expect(n.summaryStats[3].value == "worst ≥ 99%")
        #expect(n.nextTitle == "26 Nov 2026 · in 30 days")
        #expect(n.outlooks.map(\.title) == ["Coupon 4.669% (with missed ones)", "Autocall at 105%"])
        #expect(n.outlooks.allSatisfy { !$0.ok })
        #expect(n.levelsIntro == "The worst share (AMZN, 87.05%) against each level:")
        #expect(n.scenarioStats.map(\.value) == ["+USD 19,086.50", "−USD 37,250.00", "USD 6,336.50", "99%"])
        #expect(n.maturityRows.first.map { MoneyFormat.plain($0.worstPct) } == "150")
        let rows = n.scheduleRows
        #expect(rows[0].coupon == "0.667% if ≥ 98% (memory)")
        #expect(rows[0].outcomes.map(\.text) == ["Coupon missed · worst AMZN 93.11%"])
        #expect(rows[5].outcomes.count == 2)
        #expect(rows[6].pending == "to come")
        #expect(rows[6].autocall == "100% if ≥ 105%")
        #expect(n.termRows.first { $0.label == "Issuer" }?.value == "Marex Financial")

        let ended = try NoteFixtures.detail("structured_note_detail_ended")
        #expect(ended.summaryStats.map(\.label) == ["Invested", "Received", "Result", "Ended"])
        #expect(ended.summaryStats[2].value == "+USD 100.00")
        #expect(ended.levelsIntro == nil)
        #expect(ended.scheduleRows.flatMap(\.outcomes).contains { $0.text == "Called early USD 5,000.00 · worst GOOGL 103.95%" })
    }
}
