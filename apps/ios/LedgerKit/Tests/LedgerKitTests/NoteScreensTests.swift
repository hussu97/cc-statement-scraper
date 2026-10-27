import Foundation
import Testing
@testable import LedgerKit

private func day(_ iso: String) -> CalendarDay { CalendarDay(iso: iso)! }
private let profile = "prf_1"

private func swissquote(currency: String = "USD", code: String = "acc_sq") -> BankAccountBalance {
    BankAccountBalance(accountCode: code, bankCode: "SWQ", kind: "current", nickname: "Swissquote", accountRef: nil,
                       currency: currency, balance: 1000, balanceAed: 3672.5, asOf: nil)
}

private func position(_ accounts: [BankAccountBalance]) -> CashPosition {
    CashPosition(totalAed: 0, complete: true, staleCount: 0, missingCount: 0, asOf: nil, accounts: accounts)
}

@Suite("Structured notes: the screens' models")
@MainActor
struct NoteScreensTests {
    @Test("the list loads once per ledger; only live notes are listed, by paying account, without a broker's")
    func list() async throws {
        let api = StubAPI()
        api.notesFixture = try NoteFixtures.summary()
        let m = NotesModel(api: api)
        #expect(m.liveRows() == nil)   // nothing is claimed before it loads
        await m.loadIfNeeded(profileCode: profile)
        await m.loadIfNeeded(profileCode: profile)
        #expect(api.calls("structuredNotes") == 1)
        #expect(m.liveRows()?.count == 2)   // the ended note never shows
        #expect(m.note(holdingCode: "hld_01k5ys7hk0xmxhfb9100t0ncs9")?.noteStatus == .autocalled)
        let sq = "acc_01k5ys7hhab989y1ezem39ws7d"
        #expect(m.liveRows(fundingAccount: sq)?.count == 2)
        #expect(m.liveRows(fundingAccount: "acc_other")?.isEmpty == true)
        #expect(m.liveRows(excluding: ["hld_01k5ys7hj5wskbg45vcb5vtz79"])?.count == 1)
        await m.refresh(profileCode: "prf_other")
        #expect(api.calls("structuredNotes") == 1)
    }

    @Test("a note's screen: Update prices says what was stored and re-reads; Remove tells the list")
    func detail() async throws {
        let api = StubAPI()
        api.notesFixture = try NoteFixtures.summary()
        api.noteDetailFixture = try NoteFixtures.detail()
        api.pricesResult = .success(NotePriceRefresh(symbols: 3, stored: 12, settled: 0, failed: []))
        var changes: [String] = []
        let notes = NotesModel(api: api)
        notes.onChange = { changes.append($0) }
        await notes.load(profileCode: profile)
        let m = notes.detailModel(for: "hld_01k5ys7hj5wskbg45vcb5vtz79")
        await m.loadIfNeeded(profileCode: profile)
        #expect(m.canRefreshPrices(canEdit: true) && !m.canRefreshPrices(canEdit: false))
        await m.refreshPrices(profileCode: profile, canEdit: true)
        #expect(m.notice?.text == "Prices updated: 12 closes stored.")
        #expect(api.calls("structuredNoteDetail") == 2)
        #expect(changes == [profile])

        api.pricesResult = .failure(.server(status: 502, code: nil, message: "Yahoo is down"))
        await m.refreshPrices(profileCode: profile, canEdit: true)
        #expect(m.notice?.isError == true)

        #expect(await m.remove(profileCode: profile, canEdit: false) == NoteFlowText.ownerOnly)
        #expect(await m.remove(profileCode: profile, canEdit: true) == nil)
        #expect(api.cancelledNotes == ["hld_01k5ys7hj5wskbg45vcb5vtz79"])
        #expect(notes.notice?.text == "Example Bank M Phoenix AMZN/MSFT/GOOGL removed.")
    }

    @Test("a deposit or withdrawal: validated, sent as plain digits, and the money screens hear")
    func entry() async throws {
        let api = StubAPI()
        let notes = NotesModel(api: api, today: { day("2026-10-27") })
        var changed = 0
        notes.onChange = { _ in changed += 1 }
        var d = notes.newEntry(for: swissquote())
        #expect(d.amountLabel == "Amount (USD)")
        d.amount = "1.234"
        #expect(await notes.addEntry(d, profileCode: profile, canEdit: true) == "Enter the amount, e.g. 25000 or 25,000.50.")
        d.amount = "25,000.50"
        d.date = day("2026-10-28")
        #expect(await notes.addEntry(d, profileCode: profile, canEdit: true) == "The date can't be in the future.")
        d.date = day("2026-10-20")
        d.direction = .debit
        d.description = "  To Wio "
        #expect(await notes.addEntry(d, profileCode: profile, canEdit: false) == NoteFlowText.ownerOnly)
        #expect(await notes.addEntry(d, profileCode: profile, canEdit: true) == nil)
        let sent = try #require(api.accountEntries.first)
        #expect(sent.amount == "25000.50" && sent.direction == .debit && sent.description == "To Wio")
        #expect(sent.entryDate == day("2026-10-20"))
        #expect(notes.notice?.text == "Withdrawal added: USD 25,000.50.")
        #expect(changed == 1)
    }
}

@Suite("Structured notes: typed numbers and the price refresh")
struct NoteFunctionTests {
    @Test("typed numbers are cleaned like the web's cleanDecimal")
    func clean() {
        #expect(LedgerDecimal.clean("37,250.00") == "37250.00")
        #expect(LedgerDecimal.clean("98%") == "98")
        #expect(LedgerDecimal.clean("−24.5") == "-24.5")
        #expect(LedgerDecimal.clean("abc") == nil)
        #expect(LedgerDecimal.clean("1e3") == nil)
    }

    @Test("stock-prices gets JSON with the ledger and the user's JWT")
    func requests() throws {
        let f = NoteFunctions(functionsURL: URL(string: "http://127.0.0.1:54321/functions/v1")!, apiKey: "sb_publishable_x")
        let p = f.pricesRequest(profileCode: profile, accessToken: "jwt")
        #expect(p.url?.absoluteString == "http://127.0.0.1:54321/functions/v1/stock-prices")
        #expect(p.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(p.value(forHTTPHeaderField: "apikey") == "sb_publishable_x")
        #expect(p.httpBody == Data(#"{"profile_code":"prf_1"}"#.utf8))
    }

    @Test("stock-prices' answer and its notice")
    func prices() throws {
        let r = try LedgerJSON.decode(NotePriceRefresh.self, from: Data(#"{"symbols":3,"stored":1,"settled":0,"failed":["XYZ"]}"#.utf8))
        #expect(r.message == "Prices updated. No prices for: XYZ.")
        #expect(NotePriceRefresh(stored: 1).message == "Prices updated: 1 close stored.")
    }
}
