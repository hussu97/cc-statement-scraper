import Foundation
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }
private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }

/// Credit-linked notes (20261028110553): the wire and every word the screens show. The fixtures
/// are the local stack's two Example Bank N CLNs: Example Airlines (a coupon every month) and Example
/// Motors (interest paid at maturity, callable every December), as of 28 Oct 2026.
@Suite("Credit-linked notes: the wire and the words")
struct CreditNotesTests {
    static let today = day("2026-10-28")

    static func monthly() throws -> NoteDetail { try NoteFixtures.detail("structured_note_detail_cln_monthly") }
    static func atMaturity() throws -> NoteDetail { try NoteFixtures.detail("structured_note_detail_cln_at_maturity") }

    @Test("the summary decodes both notes with their credit figures; the list words their verdicts")
    func summary() throws {
        let notes = try LedgerJSON.decode([NoteSummary].self, from: fixture("structured_notes_summary_cln"))
        #expect(notes.map(\.noteType) == ["credit_linked", "credit_linked"])
        #expect(notes.allSatisfy { $0.isCreditLinked && $0.credit?.schedule.isEmpty == true && $0.worstNow == nil })
        let exm = notes[0]
        #expect(exm.credit?.callDates.count == 9 && exm.credit?.callNoticeDays == 10)
        #expect(exm.credit?.ifCalledNext?.total == dec("17436.90"))
        #expect(exm.verdict == NoteVerdict(kind: .clnAccruing, date: day("2026-12-20"), callDate: day("2026-12-20"),
                                           ratePct: dec("13.25"), amount: dec("3168.96"), maturityDate: day("2034-12-20")))

        let rows = NoteListRow.rows(notes, today: Self.today)
        #expect(rows.map(\.verdict) == ["13.25% a year, building up", "Paying 10.5% a year"])
        #expect(rows.map(\.verdictDetail) == [
            "USD 3,168.96 accrued so far, paid at maturity (20 Dec 2034) or if the issuer calls it",
            "Next coupon USD 87.50 on 20 Nov 2026 · matures 20 Dec 2031",
        ])
        #expect(rows.allSatisfy { $0.verdictTone == .neutral && $0.valueLabel == "Worth today" })
        #expect(rows.map(\.valueText) == ["USD 15,190", "USD 10,120"])
    }

    @Test("monthly coupons: verdict, entity, money, schedule and terms")
    func monthlyNote() throws {
        let n = try Self.monthly()
        let today = Self.today
        #expect(n.summary.isCreditLinked && n.terms.strikeDate == nil && n.terms.finalValuationDate == nil)
        #expect(n.outcomes.count == 25 && n.outcomes[0].worstSymbol == nil)   // coupons carry no shares
        #expect(n.headerDetail == "Example Bank N Structured Issuance SA · XS0000000108")
        #expect(n.verdictHeadline(today: today) == "Paying 10.5% a year" && n.verdictTone == .neutral)
        #expect(n.countdown(today: today) == ["Next coupon USD 87.50 on 20 Nov 2026 · matures 20 Dec 2031"])
        #expect(n.bars.isEmpty)

        let entity = try #require(n.creditEntity)
        #expect(entity.name == "Example Airlines Group Inc")
        #expect(entity.detail == "Senior · reference bond US0000AA0001")
        #expect(entity.risk == "If Example Airlines Group Inc has a credit event (default, bankruptcy or restructuring), "
            + "interest stops and the note repays what the market recovers, possibly far below 100%. At risk now: "
            + "USD 10,000.00 face value and USD 5,425.00 of interest to come; the USD 14.58 already received is kept.")

        let money = n.moneyStats(today: today)
        #expect(money.map(\.label) == ["Paid", "Worth today", "Held to maturity"])
        #expect(money.map(\.value) == ["USD 10,050", "USD 10,120", "USD 15,440"])
        #expect(money.map(\.sub) == [nil, "+USD 85 if sold today", "+USD 5,390 · 6.2% a year"])
        #expect(money[2].tone == .positive)

        #expect(n.sections.map(\.title) == ["Coupon schedule", "Terms"])
        #expect(n.couponScheduleCaption == "25 of 87 paid · USD 14.58 received · USD 5,425.00 to come")
        let rows = n.couponRows
        #expect(rows.count == 87)
        #expect(rows[0].date == "20 Oct 2024" && rows[0].amount == "USD 14.58" && rows[0].status == "Paid")
        #expect(rows[0].tone == .positive && rows[0].detail == nil && !rows[0].isNext)
        #expect(rows[25].date == "20 Nov 2026" && rows[25].status == "To come" && rows[25].isNext)
        #expect(rows.filter(\.isNext).count == 1)
        #expect(n.callDateRows(today: today).isEmpty)

        let terms = Dictionary(uniqueKeysWithValues: n.termRows.map { ($0.label, $0.value) })
        #expect(n.termRows.map(\.label) == ["Product", "Issuer", "ISIN", "Denomination", "Coupon", "Maturity", "Reference entity"])
        #expect(terms["Issuer"] == "Example Bank N Structured Issuance SA, guaranteed by Example Bank N")
        #expect(terms["Denomination"] == "USD 1,000.00 at 100% issue price")
        #expect(terms["Coupon"] == "10.5% a year, paid monthly, 30/360, from 15 Oct 2024")
        #expect(terms["Maturity"] == "20 Dec 2031; as late as 20 Dec 2032 if a credit event is being determined")
        #expect(terms["Reference entity"] == "Example Airlines Group Inc · Senior · Standard North American Corporate")
        #expect(n.hasTermSheet && n.termSheetLabel == "FinalTS-XS0000000108-EXBN-CLN-Example-Airlines-2031.pdf")
    }

    @Test("interest paid at maturity: what has built up, if called, the call dates and the one payment")
    func atMaturityNote() throws {
        let n = try Self.atMaturity()
        let today = Self.today
        #expect(n.verdictHeadline(today: today) == "13.25% a year, building up")
        #expect(n.countdown(today: today) == [
            "USD 3,168.96 accrued so far, paid at maturity (20 Dec 2034) or if the issuer calls it",
            "If called on 20 Dec 2026: USD 17,436.90 back (+USD 3,336.90)",
        ])
        #expect(n.creditEntity?.detail == "Senior · reference bond XS0000RB0002")
        #expect(n.creditEntity?.risk == "If Example Motors Automotive PLC has a credit event (default, bankruptcy or "
            + "restructuring), interest stops and the note repays what the market recovers, possibly far below 100%. At "
            + "risk now: USD 14,000.00 face value and USD 18,276.90 of interest to come, including the USD 3,168.96 accrued "
            + "so far, since nothing is paid until maturity.")

        let money = n.moneyStats(today: today)
        #expect(money.map(\.value) == ["USD 14,100", "USD 15,190", "USD 32,277"])
        #expect(money.map(\.sub) == [nil, "+USD 1,090 if sold today", "+USD 18,177 · 8.8% a year"])

        #expect(n.sections.map(\.title) == ["Coupon schedule", "Issuer call dates", "Terms"])
        #expect(n.couponScheduleCaption == "Paid in one go at maturity or on a call · USD 18,276.90 to come")
        let row = try #require(n.couponRows.first)
        #expect(n.couponRows.count == 1)
        #expect(row.date == "20 Dec 2034" && row.amount == "USD 18,276.90" && row.status == "To come" && row.isNext)
        #expect(row.detail == "interest from 13 Feb 2025 at 13.25% a year")

        let calls = n.callDateRows(today: today)
        #expect(calls.count == 9)
        #expect(calls.prefix(3).map(\.date) == ["20 Dec 2025", "20 Dec 2026", "20 Dec 2027"])
        #expect(calls.prefix(3).map(\.mark) == ["Passed", "Next", nil])
        #expect(calls[1].tone == .info)
        #expect(n.callDatesNote
            == "The issuer may repay at 100% plus accrued interest on these dates, with at least 10 business days' notice.")

        let terms = Dictionary(uniqueKeysWithValues: n.termRows.map { ($0.label, $0.value) })
        #expect(terms["Coupon"] == "13.25% a year, paid at maturity or call")
        #expect(terms["Maturity"] == "20 Dec 2034; as late as 20 Dec 2035 if a credit event is being determined")
    }

    @Test("an ended credit-linked note: its status, the equity money tiles, no countdown or risk")
    func ended() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_note_detail_cln_monthly"))
            as? [String: Any])
        var credit = try #require(json["credit"] as? [String: Any])
        for key in ["to_maturity", "if_called_next", "credit_event", "next_call_date"] { credit[key] = NSNull() }
        json["credit"] = credit
        json["status"] = "credit_event"
        json["verdict"] = ["kind": "ended"]
        json["result"] = ["total": "4114.58", "profit": "-5935.42", "return_pct": "-59.06"]
        let n = try LedgerJSON.decode(NoteDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(n.isEnded && n.summary.noteStatus.label == "Credit event" && n.summary.noteStatus.tone == .danger)
        #expect(n.verdictHeadline(today: Self.today) == nil && n.countdown(today: Self.today).isEmpty)
        #expect(n.moneyStats(today: Self.today).map(\.label) == ["Paid", "Got back", "Profit"])
        #expect(n.creditEntity?.risk == nil)
        #expect(NoteStatus(raw: "called").label == "Called by issuer" && NoteStatus(raw: "called").isEnded)
    }

    @Test("unknown types and kinds still decode; an equity note is unchanged")
    func tolerance() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: fixture("structured_note_detail")) as? [String: Any])
        json["note_type"] = "something_new"
        json["verdict"] = ["kind": "something_else", "rate_pct": "5"]
        let n = try LedgerJSON.decode(NoteDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!n.summary.isCreditLinked && n.credit == nil && n.creditEntity == nil)
        #expect(n.verdictHeadline(today: Self.today) == nil && n.summary.verdict?.creditLine(currency: "USD") == nil)
        #expect(n.sections.map(\.title) == ["All scenarios", "Full schedule", "Price history", "Terms"])
        #expect(n.termRows.map(\.label).contains("Strike"))
        #expect(NoteVerdict(kind: .onTrack).creditLine(currency: "USD") == nil)
    }

    @Test("Swissquote positions: a CLN card shows its verdict and next line, no stock bars")
    func brokerCards() throws {
        let p = try #require(try BrokerPortfolio.decode(try fixture("broker_portfolio_cln")))
        let view = BrokerPortfolioPresentation(p, now: LedgerDates.parseTimestamp("2026-10-28T12:00:00+00:00")!)
        let cards = view.notes
        #expect(cards.map(\.title) == ["Example Bank N CLN Example Motors 13.25% 2034", "Example Bank N CLN Example Airlines 10.5% 2031"])
        #expect(cards.map(\.verdict) == ["13.25% a year, building up", "Paying 10.5% a year"])
        #expect(cards[1].verdictDetail == "Next coupon USD 87.50 on 20 Nov 2026 · matures 20 Dec 2031")
        #expect(cards.allSatisfy { $0.bars.isEmpty })
        #expect(cards[0].figures.map(\.label) == ["Worth today", "Paid"])
        #expect(cards[0].figures.map(\.value) == ["USD 15,190", "USD 14,100"])
        #expect(cards[1].accessibilityLabel.contains("Next coupon USD 87.50"))
    }
}
