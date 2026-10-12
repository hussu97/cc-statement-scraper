import Foundation
import Testing
@testable import LedgerKit

@Suite("Owed now — the server's outstanding balance, worded")
struct OutstandingBalanceTests {
    let today = CalendarDay(iso: "2026-10-12")!

    @Test("what is owed, a credit balance, an estimate, and no balance")
    func text() {
        #expect(OutstandingBalance.text(Decimal(string: "515.26")!) == "AED 515.26")
        #expect(OutstandingBalance.text(Decimal(string: "-0.84")!) == "AED 0.84 in credit")
        #expect(OutstandingBalance.text(Decimal(string: "2969.79")!, hasEstimate: true) == "≈ AED 2,969.79")
        #expect(OutstandingBalance.text(nil) == "—")
    }

    @Test("the anchor note names the statement or the card replacement")
    func anchorNote() {
        #expect(OutstandingBalance.anchorNote("statement", date: CalendarDay(iso: "2026-10-01"), today: today)
            == "Statement of 1 Oct + activity since")
        #expect(OutstandingBalance.anchorNote("balance_migration", date: CalendarDay(iso: "2026-09-15"), today: today)
            == "Card replaced 15 Sep + activity since")
        #expect(OutstandingBalance.anchorNote("none", date: nil, today: today) == "No balance from the bank yet")
    }

    @Test("the total's caveat")
    func caveat() {
        #expect(OutstandingBalance.caveat(complete: true, unpricedCount: 0) == nil)
        #expect(OutstandingBalance.caveat(complete: false, unpricedCount: 1) == "Excludes 1 charge without an AED amount")
        #expect(OutstandingBalance.caveat(complete: false, unpricedCount: 3) == "Excludes 3 charges without an AED amount")
        #expect(OutstandingBalance.caveat(complete: false, unpricedCount: 0) == "Some cards have no balance from the bank yet")
    }

    @Test("overview decodes the balances per card and in total")
    func decoding() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview"))
        #expect(o.outstanding == Decimal(string: "4722.55")!)
        #expect(o.owedNowText == "≈ AED 4,722.55")
        #expect(o.owedNowCaveat == "Excludes 1 charge without an AED amount")
        let fab = AccountSummary(account: o.accounts[0])
        #expect(fab.account.balanceAnchorDate?.iso == "2026-09-25")
        #expect(fab.owedNowText == "≈ AED 4,722.55")
        #expect(fab.owedNowNote(today: today) == "Statement of 25 Sep + activity since")
        let adcb = AccountSummary(account: o.accounts[1])
        #expect(adcb.account.outstandingAed == nil)
        #expect(adcb.owedNowText == "—")
        #expect(adcb.owedNowNote(today: today) == "No balance from the bank yet")
    }

    @Test("a server without balances shows nothing rather than a guess")
    func legacy() throws {
        let o = try LedgerJSON.decode(Overview.self, from: try fixture("overview_legacy"))
        #expect(o.outstanding == nil)
        #expect(o.owedNowText == nil)
        #expect(o.owedNowCaveat == nil)
        #expect(o.accounts.allSatisfy { AccountSummary(account: $0).owedNowText == nil })
    }

    @Test("an orphaned transaction's review offers Void, which resolve_review does on dismiss")
    func orphanedReview() {
        let review = MatchReview(reviewCode: "rev_9", subjectType: "transaction", subjectCode: "txn_1", reason: "orphaned")
        let item = ReviewPresentation.item(review, inbox: ReviewInbox(reviews: [review]))
        #expect(item.options.map(\.label) == ["Void transaction"])
        #expect(item.options.map(\.action) == [.dismiss])
        #expect(item.note == nil)
        #expect(ReviewPresentation.help("orphaned").contains("Void them once checked"))
    }
}
