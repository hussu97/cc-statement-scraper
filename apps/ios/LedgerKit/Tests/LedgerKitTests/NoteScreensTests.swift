import Foundation
import Supabase
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
    @Test("the list loads once per ledger, groups live then ended, and filters by paying account")
    func list() async throws {
        let api = StubAPI()
        api.notesFixture = try NoteFixtures.summary()
        let m = NotesModel(api: api)
        await m.loadIfNeeded(profileCode: profile)
        await m.loadIfNeeded(profileCode: profile)
        #expect(api.calls("structuredNotes") == 1)
        #expect(m.groups().live.count == 2)
        #expect(m.note(holdingCode: "hld_01k5ys7hk0xmxhfb9100t0ncs9")?.noteStatus == .autocalled)
        let sq = "acc_01k5ys7hhab989y1ezem39ws7d"
        #expect(m.showsCard(fundingAccount: sq, bankCode: "SWQ", canEdit: false))
        #expect(!m.showsCard(fundingAccount: "acc_other", bankCode: "ENBD", canEdit: true))
        #expect(m.showsCard(fundingAccount: "acc_other", bankCode: "SWQ", canEdit: true))
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

    @Test("adding: read the sheet, pick the one account in its currency, refuse what can't be saved, save, then fetch prices")
    func add() async throws {
        let api = StubAPI()
        api.extractResult = .success(try NoteFixtures.extract())
        api.cashPositionFixture = position([swissquote(), swissquote(currency: "AED", code: "acc_aed")])
        api.notesFixture = []
        let notes = NotesModel(api: api, today: { day("2026-10-27") })
        var changed = 0
        notes.onChange = { _ in changed += 1 }
        let m = notes.addModel()
        await m.extract(UploadFile(filename: "athena.pdf", data: Data("%PDF".utf8)), profileCode: profile, canEdit: true)
        #expect(m.phase == .review)
        #expect(m.warnings.count == 1)
        #expect(m.accounts.map(\.accountCode) == ["acc_sq"])
        #expect(m.form.fundingAccountCode == "acc_sq")
        #expect(m.form.tradeDate == day("2026-09-11"))
        #expect(m.pricePlaceholder == "54")

        #expect(await m.save(profileCode: profile, canEdit: true) == nil)
        #expect(m.error == "MICROSOFT CORP: enter its price symbol (e.g. AMZN). Enter how much you invested (up to 2 decimals).")
        m.setSymbol(2, "msft")
        m.form.investedAmount = "5,400"
        m.setName("  Athena 2031 ")
        #expect(await m.save(profileCode: profile, canEdit: true) == "hld_note")
        #expect(api.createdNotes.first?.draft.terms.underlyings[2].symbol == "MSFT")
        #expect(api.calls("refreshNotePrices") == 1)
        #expect(m.savedMessage == "Athena 2031 added: prices are in, its status is up to date.")
        #expect(notes.notice?.text == m.savedMessage)
        #expect(changed == 1)
    }

    @Test("a sheet that can't be read goes back to choosing, in words")
    func extractFails() async {
        let api = StubAPI()
        api.extractResult = .failure(.server(status: 422, code: "NOT_A_TERM_SHEET", message: "not a term sheet"))
        let m = AddNoteModel(api: api)
        await m.extract(UploadFile(filename: "x.pdf", data: Data()), profileCode: profile, canEdit: true)
        #expect(m.phase == .choosing)
        #expect(m.error == "That PDF doesn't look like a term sheet. Choose the issuer's final terms.")
        await m.extract(UploadFile(filename: "x.pdf", data: Data()), profileCode: profile, canEdit: false)
        #expect(m.error == NoteFlowText.ownerOnly)
        #expect(api.extractedFiles.count == 1)
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

@Suite("Structured notes: the term-sheet draft and the functions")
struct NoteDraftTests {
    @Test("the extract decodes with its raw answer intact, and the draft goes back as create_structured_note's p_draft")
    func params() throws {
        var draft = try NoteFixtures.extract().draft
        #expect(draft.termsSummary == "USD · 1 denomination at 54% · strike 27 Aug 2026 · matures 4 Sep 2031")
        #expect(draft.payoutRows.map(\.pays) == ["100%", "WP − 45%", "0%"])
        draft.terms.underlyings[2].symbol = "msft"
        var form = NoteDraftForm(tradeDate: CalendarDay(iso: "2026-08-27")!, fundingAccountCode: "acc_sq")
        form.investedAmount = "5,400.00"
        #expect(form.problems(draft).isEmpty)
        guard case let .object(p) = form.params(draft, institution: "Swissquote") else { Issue.record("not an object"); return }
        guard case let .object(terms)? = p["terms"], case let .object(inv)? = p["investment"],
              case let .array(unds)? = terms["underlyings"], case let .object(u3) = unds[2],
              case let .object(raw)? = p["extracted_terms"] else { Issue.record("shape"); return }
        #expect(u3["symbol"] == .string("MSFT"))
        #expect(inv["invested_amount"] == .string("5400.00"))
        #expect(inv["purchase_price_pct"] == .null)
        #expect(inv["funding_account_code"] == .string("acc_sq"))
        #expect(p["institution"] == .string("Swissquote"))
        // The model's raw answer keeps its snake_case keys.
        #expect(raw["product_name"] == .string("5Y Athena"))
        guard case let .array(payout)? = terms["payout"], case let .object(b0) = payout[0] else { Issue.record("payout"); return }
        #expect(b0["description"] == nil)
    }

    @Test("typed numbers are cleaned like the web's cleanDecimal")
    func clean() {
        #expect(NoteDraftForm.clean("37,250.00") == "37250.00")
        #expect(NoteDraftForm.clean("98%") == "98")
        #expect(NoteDraftForm.clean("−24.5") == "-24.5")
        #expect(NoteDraftForm.clean("abc") == nil)
        #expect(NoteDraftForm.clean("1e3") == nil)
    }

    @Test("termsheet-extract gets one PDF as `file` with the ledger; stock-prices gets JSON")
    func requests() throws {
        let f = NoteFunctions(functionsURL: URL(string: "http://127.0.0.1:54321/functions/v1")!, apiKey: "sb_publishable_x")
        let r = f.extractRequest(file: UploadFile(filename: "sheet.pdf", data: Data("%PDF-1.7".utf8)), profileCode: profile,
                                 accessToken: "jwt")
        #expect(r.url?.absoluteString == "http://127.0.0.1:54321/functions/v1/termsheet-extract")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(r.value(forHTTPHeaderField: "apikey") == "sb_publishable_x")
        let body = String(decoding: try #require(r.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"profile_code\"\r\n\r\nprf_1\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"sheet.pdf\"\r\nContent-Type: application/pdf"))
        #expect(r.timeoutInterval >= 150)
        let p = f.pricesRequest(profileCode: profile, accessToken: "jwt")
        #expect(p.url?.lastPathComponent == "stock-prices")
        #expect(p.httpBody == Data(#"{"profile_code":"prf_1"}"#.utf8))
    }

    @Test("stock-prices' answer and its notice")
    func prices() throws {
        let r = try LedgerJSON.decode(NotePriceRefresh.self, from: Data(#"{"symbols":3,"stored":1,"settled":0,"failed":["XYZ"]}"#.utf8))
        #expect(r.message == "Prices updated. No prices for: XYZ.")
        #expect(NotePriceRefresh(stored: 1).message == "Prices updated: 1 close stored.")
    }
}
