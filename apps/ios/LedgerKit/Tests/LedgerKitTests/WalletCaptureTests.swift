import Foundation
import Supabase
import Testing
@testable import LedgerKit

private func dec(_ s: String) -> Decimal { LedgerDecimal.parse(s)! }

@Suite("Card payments — checked on the phone, amount sent as a decimal string")
struct WalletCaptureTests {
    let at = Date(timeIntervalSince1970: 1_791_436_364)

    @Test("normalises: trims and collapses whitespace, uppercases the currency, rounds half-up to cents")
    func normalises() throws {
        let p = try WalletCapture.payment(amount: dec("12.345"), currency: " aed ", merchant: "  CARREFOUR \n CITY  ",
                                          passName: " Wio  Credit ", occurredAt: at).get()
        #expect(p.amount == dec("12.35"))
        #expect(p.currency == "AED")
        #expect(p.merchant == "CARREFOUR CITY")
        #expect(p.passName == "Wio Credit")
        #expect(p.occurredAt == at)
    }

    @Test("caps merchant at 200 and card name at 64 characters")
    func caps() throws {
        let p = try WalletCapture.payment(amount: 1, currency: "AED", merchant: String(repeating: "m", count: 300),
                                          passName: String(repeating: "c", count: 100)).get()
        #expect(p.merchant.count == 200)
        #expect(p.passName.count == 64)
    }

    @Test("refuses what the server would refuse", arguments: [
        ("0", "AED", "Shop", "Card", WalletCapture.Problem.invalidAmount),
        ("0.004", "AED", "Shop", "Card", .invalidAmount),
        ("-5", "AED", "Shop", "Card", .invalidAmount),
        ("1000000000000", "AED", "Shop", "Card", .invalidAmount),
        ("5", "", "Shop", "Card", .invalidCurrency),
        ("5", "dirham", "Shop", "Card", .invalidCurrency),
        ("5", "AE1", "Shop", "Card", .invalidCurrency),
        ("5", "AED", "   ", "Card", .missingMerchant),
        ("5", "AED", "Shop", " \n ", .missingCard),
    ])
    func refuses(amount: String, currency: String, merchant: String, card: String, problem: WalletCapture.Problem) {
        let result = WalletCapture.payment(amount: dec(amount), currency: currency, merchant: merchant, passName: card)
        #expect(throws: problem) { try result.get() }
        #expect(!problem.userMessage.contains("Shop"))
    }

    @Test("wire item: lowercase id, ISO time, amount as a JSON string (never a number)")
    func wire() throws {
        let id = UUID(uuidString: "6F1C2A8E-8A0B-4F7E-9D61-2C1F6A3B9E10")!
        let p = try WalletCapture.payment(amount: dec("1234567.80"), currency: "AED", merchant: "IKEA",
                                          passName: "Wio", occurredAt: at, clientMsgId: id).get()
        guard case .object(let o) = p.json else { Issue.record("not an object"); return }
        #expect(o["client_msg_id"] == .string("6f1c2a8e-8a0b-4f7e-9d61-2c1f6a3b9e10"))
        #expect(o["amount"] == .string("1234567.8"))
        #expect(o["currency"] == .string("AED"))
        #expect(o["merchant"] == .string("IKEA"))
        #expect(o["pass_name"] == .string("Wio"))
        #expect(o["occurred_at"] == .string(LedgerDates.isoTimestamp(at)))
    }

    @Test("persists exactly: the amount round-trips as a string through the outbox's JSON")
    func persists() throws {
        let p = WalletPayment(occurredAt: at, amount: dec("0.10"), currency: "AED", merchant: "Café", passName: "Wio")
        let data = try LedgerJSON.makeEncoder().encode(p)
        #expect(String(decoding: data, as: UTF8.self).contains(#""amount":"0.1""#))
        let back = try LedgerJSON.decode(WalletPayment.self, from: data)
        #expect(back == p)
    }

    @Test("Settings preview of a parked payment names the card and amount")
    func parkedPreview() {
        let p = WalletPayment(occurredAt: at, amount: dec("45.10"), currency: "AED", merchant: "Carrefour", passName: "Wio")
        let entry = OutboxEntry(item: .wallet(p), profileCode: "prf_a", enqueuedAt: at, nextAttemptAt: at,
                                parkedAt: at, parkedReason: "Ledger rejected this message: its amount isn't above zero.")
        let row = ParkedMessage(entry)
        #expect(row.sender == "Card payment · Wio")
        #expect(row.preview == "AED 45.1 at Carrefour")
        #expect(row.receivedAt == at)
    }
}

@Suite("Card names — wallet_name rules and errors")
struct WalletNameTests {
    @Test("normalise: trimmed and collapsed; empty clears")
    func normalise() {
        #expect(WalletName.normalise("  Wio   Credit ") == "Wio Credit")
        #expect(WalletName.normalise("   ") == nil)
        #expect(WalletName.validate(String(repeating: "x", count: 65)) != nil)
        #expect(WalletName.validate(String(repeating: "x", count: 64)) == nil)
        #expect(WalletName.validate("") == nil)
    }

    @Test("a name another card has (23505) is a sentence")
    func clash() {
        let e = LedgerAPIError.server(status: nil, code: "23505", message: "duplicate key value violates unique constraint")
        #expect(WalletName.errorMessage(e) == "Another card in this ledger already has that name.")
    }

    @Test("model: owners save, the list reloads; a clash stays on the card")
    @MainActor
    func model() async {
        let stub = StubAPI()
        stub.cardRows = [
            LedgerCard(cardCode: "crd_b", accountCode: "acc_1", bankCode: "WIO", last4: "2222", status: "closed"),
            LedgerCard(cardCode: "crd_a", accountCode: "acc_1", bankCode: "WIO", last4: "1111"),
        ]
        let model = CardWalletNamesModel(api: stub)
        await model.load(profileCode: "prf_a")
        #expect(model.cards.map(\.cardCode) == ["crd_a", "crd_b"])
        #expect(model.cards[1].label == "WIO •2222 · closed")

        #expect(await model.save(model.cards[0], name: "  Wio  Credit "))
        #expect(stub.walletNameWrites.first?.name == "Wio Credit")
        #expect(model.cards[0].walletName == "Wio Credit")

        // Unchanged: no write.
        #expect(await model.save(model.cards[0], name: "Wio Credit"))
        #expect(stub.walletNameWrites.count == 1)

        stub.cardWriteError = .server(status: nil, code: "23505", message: "duplicate")
        #expect(await model.save(model.cards[1], name: "wio credit") == false)
        #expect(model.errors["crd_b"] == "Another card in this ledger already has that name.")
    }
}

@Suite("ingest_wallet_transactions — 'invalid' reasons in words")
struct WalletContractTests {
    @Test("each wallet_input_problem reason has a sentence", arguments: [
        "invalid_occurred_at", "invalid_amount", "invalid_currency", "invalid_merchant", "invalid_pass_name",
    ])
    func reasons(reason: String) {
        let r = SMSIngestResult(clientMsgId: "x", smsCode: nil, status: "invalid", txnCode: nil, reason: reason)
        #expect(r.isFailure)
        #expect(!r.failureReason.contains(reason))
    }

    @Test("cards decode with wallet_name (null or set)")
    func decodesCards() throws {
        let json = """
        [{"card_code":"crd_1","account_code":"acc_1","bank_code":"WIO","last4":"1234","status":"active","wallet_name":"Wio Credit"},
         {"card_code":"crd_2","account_code":"acc_1","bank_code":"FAB","last4":"5678","status":"replaced","wallet_name":null}]
        """
        let cards = try LedgerJSON.decode([LedgerCard].self, from: Data(json.utf8))
        #expect(cards[0].walletName == "Wio Credit")
        #expect(cards[1].walletName == nil)
        #expect(cards[1].label == "FAB •5678 · replaced")
    }
}
