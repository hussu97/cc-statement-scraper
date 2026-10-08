import Foundation
import Testing
@testable import LedgerKit

@Suite("statement_detail: wire shape and what the detail screen says")
struct StatementDetailTests {
    let today = CalendarDay(iso: "2026-10-15")!

    @Test("decodes the RPC's decimal strings and line fields exactly")
    func decode() throws {
        let d = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail"))
        #expect(d.statement.bankCode == "FAB")
        #expect(d.statement.cardLast4s == ["1234", "5678"])
        #expect(MoneyFormat.plain(d.statement.closingBalance!) == "4210.55")
        #expect(d.statement.reconChecks?.balanceEquation == false)
        #expect(d.statement.reconChecks?.expectedClosing == Decimal(string: "4210.50")!)
        #expect(d.debits.count == 2)
        #expect(MoneyFormat.plain(d.debits.total) == "5120.1")
        #expect(d.credits.lines[0].kind == "payment")
        let fx = d.debits.lines[0]
        #expect(fx.amountAed == Decimal(string: "45.32")!)
        #expect(fx.amountOriginal == Decimal(string: "12.34")!)
        #expect(d.debits.lines[1].txnCode == nil)
    }

    @Test("header: cards, period with year, tiles with a dash for figures the PDF lacks, due wording")
    func header() throws {
        let h = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail")).statement
        #expect(h.cardsLabel == "•1234 · •5678")
        #expect(h.periodLabel == "26 Aug – 25 Sep 2026")
        #expect(h.tiles.map(\.title) == ["Opening balance", "Total debits", "Total credits", "Closing balance",
                                         "Minimum due", "Credit limit"])
        #expect(h.tiles[1].value == "AED 5,120.10")
        #expect(h.due(isLatest: true, today: today)?.text == "Due in 5 days")

        let empty = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail_empty"))
        #expect(empty.statement.cardsLabel == nil)
        #expect(empty.statement.periodLabel == nil)
        #expect(empty.statement.kindLabel == "History extract")
        #expect(empty.statement.tiles.count == 5)
        #expect(empty.statement.tiles.allSatisfy { $0.value == "—" })
        #expect(empty.debits.lines.isEmpty && empty.credits.count == 0)
    }

    @Test("recon: every check becomes a sentence with the server's figures")
    func recon() throws {
        let d = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail"))
        let findings = ReconPresentation.findings(status: d.statement.reconStatus, checks: d.statement.reconChecks,
                                                  header: d.statement)
        #expect(findings.map(\.text) == [
            "Debit lines add up to the statement's total debits (AED 5,120.10).",
            "Credit lines add up to the statement's total credits (AED 1,909.55).",
            "Opening balance + debits − credits gives AED 4,210.50, not the closing balance of AED 4,210.55.",
            "1 line is waiting in Review.",
            "2 SMS alerts from this period aren't on the statement.",
            "67% of lines were also seen by SMS.",
        ])
        #expect(findings.map(\.passed) == [true, true, false, nil, nil, nil])
        #expect(ReconPresentation.status("warn") == ("Check", .warn))

        let empty = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail_empty"))
        let none = ReconPresentation.findings(status: "n/a", checks: empty.statement.reconChecks, header: empty.statement)
        #expect(none.map(\.text) == ["A history extract has no totals, so there is nothing to check its lines against."])
    }

    @Test("lines: merchant over printed text, FX original, kind chip, VoiceOver sentence")
    func lines() throws {
        let d = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail"))
        let fx = d.debits.lines[0]
        let held = d.debits.lines[1]
        let dune = try LedgerJSON.decode(StatementDetail.Line.self, from: Data("""
            {"line_code": "stl_d", "txn_code": "txn_d", "txn_date": "2026-08-26", "description": "DUNE COFFEE ROASTERS DUBAI AE",
             "merchant_name": "Dune Coffee Roasters", "amount_aed": "27.28"}
            """.utf8))
        #expect(dune.printedDetail == nil)
        #expect(fx.title == "Amazon")
        #expect(fx.printedDetail == "AMZN MKTP US*2K4QJ71Z0")
        #expect(held.title == "CARREFOUR MOE DUBAI")
        #expect(fx.amountLabel(isCredit: false) == "AED 45.32")
        #expect(fx.originalLabel == "USD 12.34")
        #expect(fx.kindLabel == nil)
        #expect(fx.canOpen)
        #expect(fx.accessibilityLabel(isCredit: false, categoryName: "Shopping")
                == "Amazon, 28 Aug, AED 45.32, originally USD 12.34, Shopping")

        #expect(held.categoryLabel(nil) == "Not matched yet")
        #expect(fx.categoryLabel(nil) == "Uncategorised" && fx.categoryLabel("Shopping") == "Shopping")
        #expect(held.printedDetail == nil)
        #expect(held.originalLabel == nil)
        #expect(!held.canOpen)
        #expect(held.accessibilityLabel(isCredit: false, categoryName: nil).hasSuffix("not matched to a transaction"))

        let payment = d.credits.lines[0]
        #expect(payment.amountLabel(isCredit: true) == "+ AED 1,909.55")
        #expect(payment.kindLabel == "Payment")
        #expect(d.credits.summary == "1 · AED 1,909.55")
    }

    @Test("model: loads with categories, opens a line's transaction, explains a missing statement")
    @MainActor
    func model() async throws {
        let api = StubAPI()
        api.detail = try LedgerJSON.decode(StatementDetail.self, from: try fixture("statement_detail"))
        api.categoryOptions = [FilterMeta.CategoryOption(categoryCode: "cat_01hzy3k8w9m2n4p6q8r0s2t4c1", name: "Shopping",
                                                         kind: "expense", colorToken: "cat-4", parentCode: nil, archived: false)]
        let txn = try LedgerJSON.decode([LedgerTransaction].self, from: try fixture("transactions"))[0]
        api.transactionRows = ["prf_a": [txn]]
        let model = StatementDetailModel(api: api, stmtCode: "stm_x", isLatest: true)
        await model.load(profileCode: "prf_a")
        let content = try #require(model.state.value)
        #expect(content.categories["cat_01hzy3k8w9m2n4p6q8r0s2t4c1"]?.colorToken == "cat-4")
        #expect(content.assignable.count == 1)

        // The fixture line's txn_code isn't in the stub: a sentence, no sheet.
        await model.open(content.detail.debits.lines[0], profileCode: "prf_a")
        #expect(model.selected == nil)
        #expect(model.errorMessage?.contains("no longer in this ledger") == true)

        let linked = try LedgerJSON.decode(StatementDetail.Line.self, from: Data("""
            {"line_code": "stl_1", "txn_code": "\(txn.txnCode)", "txn_date": "2026-10-01", "description": "AMAZON",
             "amount_aed": "45.32", "amount_original": "12.34", "currency_original": "USD"}
            """.utf8))
        await model.open(linked, profileCode: "prf_a")
        #expect(model.selected?.txnCode == txn.txnCode)
        #expect(model.opening == nil)

        api.detailError = .server(status: nil, code: "P0002", message: "unknown statement stm_x")
        await model.load(profileCode: "prf_a")
        #expect(model.state.errorMessage == "This statement is no longer in this ledger. It may have been replaced by a newer upload.")
    }

    @Test("bank logos replace the bank code in row text")
    func cardSuffixes() throws {
        let rows = try LedgerJSON.decode([LedgerTransaction].self, from: try fixture("transactions"))
        #expect(rows[0].cardSuffix == "•1234")
        let cycles = try LedgerJSON.decode([StatementCycle].self, from: try fixture("statement_cycles"))
        #expect(cycles[0].cardSuffix == "•1234")
        #expect(cycles[1].cardSuffix == "History extract")

        let review = MatchReview(reviewCode: "rev_1", subjectType: "sms", subjectCode: "sms_1", reason: "unknown_card",
                                 candidates: [.init(txnCode: nil, bankCode: "ADCB", last4: "9208", templateCode: nil)])
        let inbox = ReviewInbox(reviews: [review], sms: ["sms_1": ReviewSMS(
            smsCode: "sms_1", bankCode: "ADCB", cardLast4: "9208", amount: Decimal(string: "46.00"), currency: "AED",
            merchantRaw: "VOX CINEMAS", receivedAt: Date(timeIntervalSince1970: 1_791_436_364))])
        let item = ReviewPresentation.item(review, inbox: inbox)
        #expect(item.bankCode == "ADCB")
        #expect(item.subject == "ADCB •9208 · AED 46.00 · VOX CINEMAS")
        #expect(item.subjectBody == "•9208 · AED 46.00 · VOX CINEMAS")
    }
}

@Suite("Bank logos: bundled first, then the bucket, then a monogram")
struct BankDirectoryTests {
    let base = URL(string: "http://127.0.0.1:54321")!

    @Test func sources() {
        #expect(BankDirectory.source(bankCode: "FAB", logoPath: "FAB.png", supabaseURL: base) == .bundled(assetName: "Bank/FAB"))
        #expect(BankDirectory.source(bankCode: "RAKBANK", logoPath: "RAKBANK.png", supabaseURL: base)
                == .remote(URL(string: "http://127.0.0.1:54321/storage/v1/object/public/bank-logos/RAKBANK.png")!))
        #expect(BankDirectory.source(bankCode: "CBD", logoPath: nil, supabaseURL: base) == .monogram("CB"))
        // A path that would leave the bucket is refused.
        #expect(BankDirectory.source(bankCode: "CBD", logoPath: "../x.png", supabaseURL: base) == .monogram("CB"))
    }

    @Test("dark marks get the light chip in dark mode only")
    func chip() {
        #expect(BankDirectory.needsLightChip(bankCode: "ENBD", darkMode: true))
        #expect(BankDirectory.needsLightChip(bankCode: "fab", darkMode: true))
        #expect(!BankDirectory.needsLightChip(bankCode: "ENBD", darkMode: false))
        #expect(!BankDirectory.needsLightChip(bankCode: "ADCB", darkMode: true))
        #expect(!BankDirectory.needsLightChip(bankCode: "MASHREQ", darkMode: true))
    }

    @Test("catalog: table names win, the seed covers offline, senders map to banks")
    @MainActor
    func catalog() async throws {
        let rows = try LedgerJSON.decode([BankInfo].self, from: try fixture("banks"))
        #expect(rows[1].logoPath == "RAKBANK.png")
        let catalog = BankCatalog(supabaseURL: base, load: { rows })
        #expect(catalog.name(for: "ENBD") == "Emirates NBD")       // seed, before the read
        #expect(catalog.name(for: "RAKBANK") == "RAKBANK")
        await catalog.refresh()
        #expect(catalog.name(for: "CBD") == "Commercial Bank of Dubai")
        #expect(catalog.name(for: "XYZ") == "XYZ")
        #expect(catalog.bankCode(forSender: "adcbalert") == "ADCB")
        #expect(catalog.bankCode(forSender: "Unknown") == nil)
        #expect(catalog.source(for: "RAKBANK") == .remote(URL(string: "http://127.0.0.1:54321/storage/v1/object/public/bank-logos/RAKBANK.png")!))
    }
}
