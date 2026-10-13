import Foundation
import Testing
@testable import LedgerKit

@Suite("A paid statement leaves the due widget and What's Due")
struct WidgetPaidStatementTests {
    /// The overview fixture with the FAB statement's payment status.
    func paidSnapshot(_ status: String, paid: String, now: Date = widgetNow) throws -> WidgetSnapshot {
        let json = try #require(String(data: try fixture("overview"), encoding: .utf8)).replacingOccurrences(
            of: #""min_due": "210.53"}"#,
            with: #""min_due": "210.53", "payment_status": "\#(status)", "amount_paid": "\#(paid)"}"#)
        let overview = try LedgerJSON.decode(Overview.self, from: Data(json.utf8))
        return try #require(WidgetSnapshot.make(overview: overview, profileCode: "prf_a", ledgerName: "Home", now: now))
    }

    @Test("the snapshot keeps the latest statement's payment status and amount paid; they round-trip")
    func copied() throws {
        let s = try paidSnapshot("part_paid", paid: "1000")
        #expect(s.cards[0].paymentStatus == "part_paid")
        #expect(s.cards[0].amountPaid == LedgerDecimal.parse("1000"))
        #expect(s.cards[0].duePayment == DuePayment(status: .partPaid, amountPaid: 1000))
        #expect(s.cards[1].paymentStatus == nil && s.cards[1].amountPaid == nil)
        let data = try s.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""payment_status":"part_paid""#))
        #expect(json.contains(#""amount_paid":"1000""#))
        #expect(WidgetSnapshot.decode(data) == s)
    }

    @Test("a snapshot written before payment status was kept still decodes, with no status")
    func oldSnapshot() throws {
        let old = #"""
        {"version": 1, "generated_at": "2026-10-13T08:00:00Z", "profile_code": "prf_a", "ledger_name": "Home",
         "month": "2026-10-01", "spend": "860", "spend_prev_month_to_date": "1000",
         "change_vs_prev_month_to_date": "-0.14", "uncategorized_count": 2,
         "cards": [{"account_code": "acc_a", "title": "FAB", "due_date": "2026-10-20",
                    "closing_balance": "4210.55", "min_due": "210.53", "utilisation": "0.14"}]}
        """#
        let s = try #require(WidgetSnapshot.decode(Data(old.utf8)))
        #expect(s.cards.count == 1)
        #expect(s.cards[0].closingBalance == LedgerDecimal.parse("4210.55"))
        #expect(s.cards[0].paymentStatus == nil && s.cards[0].amountPaid == nil && s.cards[0].duePayment == nil)
        #expect(WidgetDue.upcoming(s.cards, today: CalendarDay(year: 2026, month: 10, day: 13)).count == 1)
    }

    @Test("a change of payment status alone reloads the widgets")
    func reloads() throws {
        let unpaid = try paidSnapshot("unpaid", paid: "0")
        let paid = try paidSnapshot("paid", paid: "4210.55", now: widgetNow.addingTimeInterval(60))
        #expect(!paid.sameContent(as: unpaid))
        #expect(paid.needsReload(replacing: unpaid))
        let partPaid = try paidSnapshot("part_paid", paid: "4210.55", now: widgetNow.addingTimeInterval(60))
        #expect(partPaid.needsReload(replacing: paid))
    }

    @Test("upcoming leaves out what the server marks paid; part paid, unpaid and unknown stay")
    func upcoming() {
        let today = CalendarDay(year: 2026, month: 10, day: 13)
        let cards = [card("a", due: "2026-10-15", payment: "paid", paid: "100"),
                     card("b", due: "2026-10-16", payment: "part_paid", paid: "40"),
                     card("c", due: "2026-10-17", payment: "unpaid"),
                     card("d", due: "2026-10-18"),
                     card("e", due: "2026-10-19", payment: "something_new")]
        #expect(WidgetDue.upcoming(cards, today: today).map(\.accountCode) == ["b", "c", "d", "e"])
    }

    @Test("the due widget skips a paid statement and words a part-paid one from the server's status")
    func dueWidget() throws {
        let cards = [card("a", due: "2026-10-15", payment: "paid", paid: "100"),
                     card("b", due: "2026-10-18", payment: "part_paid", paid: "40")]
        let c = DueWidgetContent.make(snapshot: snapshot(cards: cards), placement: .homeScreen, requireAuth: false,
                                      now: widgetNow)
        #expect(c.card == "Card b")
        #expect(c.when == "Part paid (AED 40.00) · Due in 5 days")
        #expect(c.whenTone == .warn)
        #expect(c.others == nil)

        // A locked-down Lock Screen says part paid, but not how much.
        let hidden = DueWidgetContent.make(snapshot: snapshot(cards: cards), placement: .lockScreen, requireAuth: true,
                                           now: widgetNow)
        #expect(hidden.when == "Part paid · Due in 5 days")
        #expect(!hidden.accessibilityLabel.contains("AED") && !hidden.inline.contains("AED"))

        // From the server's overview: FAB paid in full, so nothing is due.
        let paid = DueWidgetContent.make(snapshot: try paidSnapshot("paid", paid: "4210.55"), placement: .homeScreen,
                                         requireAuth: false, now: widgetNow)
        #expect(paid.card == nil)
        #expect(paid.message == "Nothing due. Every upcoming statement is paid.")
    }

    @Test("nothing due: paid ahead, passed, or no statements, each said only when the data shows it")
    func whyNothingDue() {
        let today = CalendarDay(year: 2026, month: 10, day: 13)
        #expect(WidgetDue.whyNothingDue([card("a", due: "2026-10-20", payment: "paid"), card("b", due: "2026-10-01")],
                                        today: today) == .paid)
        #expect(WidgetDue.whyNothingDue([card("b", due: "2026-10-01", payment: "paid")], today: today) == .passed)
        #expect(WidgetDue.whyNothingDue([card("d", due: nil)], today: today) == .noStatements)
    }

    @Test("What's Due skips a paid statement, says part paid, and says when everything ahead is paid")
    func whatsDue() async throws {
        let api = StubAPI()
        api.overviewError = .network("-1009")
        let cards = [card("a", due: "2026-10-15", payment: "paid", paid: "100"),
                     card("b", due: "2026-10-18", payment: "part_paid", paid: "40"),
                     card("c", due: "2026-10-20")]
        let mixed = LedgerQuestions(api: api, profileCode: { "prf_a" }, snapshot: { snapshot(cards: cards) })
        let answer = await mixed.whatsDue(now: widgetNow)
        #expect(answer.count == 2)
        #expect(answer.dialog == "Offline, as of 12:00: Card b: AED 100.00 part paid (AED 40.00), due in 5 days (18 Oct). "
                + "Card c: AED 100.00 due in 7 days (20 Oct).")

        let allPaid = LedgerQuestions(api: api, profileCode: { "prf_a" },
                                      snapshot: { snapshot(cards: [card("a", due: "2026-10-15", payment: "paid")]) })
        let none = await allPaid.whatsDue(now: widgetNow)
        #expect(none.count == 0)
        #expect(none.dialog.hasSuffix("Nothing is due: every upcoming statement is paid."))

        // From the server: the overview's FAB statement, paid.
        let server = StubAPI()
        let json = try #require(String(data: try fixture("overview"), encoding: .utf8)).replacingOccurrences(
            of: #""min_due": "210.53"}"#, with: #""min_due": "210.53", "payment_status": "paid", "amount_paid": "4210.55"}"#)
        server.overviewFixture = try LedgerJSON.decode(Overview.self, from: Data(json.utf8))
        let fresh = await LedgerQuestions(api: server, profileCode: { "prf_a" }, snapshot: { nil }).whatsDue(now: widgetNow)
        #expect(fresh.count == 0 && fresh.dialog == "Nothing is due: every upcoming statement is paid.")
    }
}
