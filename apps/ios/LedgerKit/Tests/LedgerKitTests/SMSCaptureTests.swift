import Foundation
import Testing
@testable import LedgerKit

@Suite("SMS filter — runs on the phone before anything is sent")
struct SMSCaptureTests {
    @Test("OTPs are always dropped", arguments: [
        "Your OTP for AED 250.00 at AMAZON on card ending 1234 is 482913.",
        "482913 is your One-Time Password for the transaction of AED 12.00 on Credit Card XXX1234",
        "Use one time passcode 1234 to complete your purchase",
        "Your onetime PIN is 9921",
        "Verification code: 551204. Do not share it.",
        "Your passcode is 1234",
        "Your pass code is 1234",
        "Security code 8812 for your FAB Credit Card transaction of USD 20.00",
        "OTP:123456 for txn of AED 99",
    ])
    func dropsOTPs(body: String) {
        #expect(SMSCapture.isOTP(body))
        #expect(SMSCapture.classify(body: body) == .dropOTP)
    }

    @Test("credit-card transactions are accepted", arguments: [
        "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE on 08/10/2026 09:12. Avl limit AED 25,000.00",
        "Purchase of AED 1,250.00 with Credit Card ending 5678 at IKEA DUBAI. Available limit AED 10,212.50",
        "Your Cr.Card XXX4321 was used for USD 12.34 at AMAZON.COM on 07-OCT-26",
        "Transaction of AED 99.00 on your Mashreq Credit Card ending 0001 at NOON.COM",
        "Refund of AED 120.00 to your card ending 1234 from NOON has been processed",
        "Payment of AED 5,000.00 received for card ending 1234. Thank you.",
        "Txn of EUR 30.00 at ZARA PARIS on card 1234.",
        "Your credit card a/c ending 1234 has been charged AED 10.00 annual fee",
    ])
    func acceptsCreditCard(body: String) {
        #expect(SMSCapture.classify(body: body) == .accept)
    }

    // The phone used to guess "not a credit card" and drop these; a wrong guess
    // lost the message for good. The server's templates now decide (stored as
    // `ignored` or `unparsed`), so everything but an OTP leaves the phone.
    @Test("everything that is not an OTP is sent for the server to classify", arguments: [
        "Payment of AED 12.50 to noon one with Credit Card ending 0000. Avl Cr. Limit is AED 1,000.00.",
        "Your Debit Card ending 1234 was used for AED 45.00 at ENOC",
        "AED 12,000.00 salary credited to your a/c XXX9876. Avl bal AED 15,212.00",
        "Your account XXXX9876 has been debited AED 500.00 via transfer to JOHN",
        "Funds transfer of AED 1,000.00 completed",
        "Your DC ending 1234 was used for AED 10.00",
        "Purchase of Rs. 500 on card ending 1234 at CAFE",
        "Your new card has been dispatched.",
        "EmiratesNBD",
    ])
    func sendsEverythingElse(body: String) {
        #expect(SMSCapture.classify(body: body) == .accept)
    }

    @Test func dropsEmpty() {
        #expect(SMSCapture.classify(body: "   \n") == .dropEmpty)
    }

    @Test("an accepted message becomes a trimmed payload with a fresh client_msg_id")
    func payload() throws {
        let at = Date(timeIntervalSince1970: 1_791_436_364)
        let (decision, payload) = SMSCapture.payload(
            body: "  Purchase of AED 45.10 with Credit Card ending 1234 at CARREFOUR \n", sender: " FAB ", receivedAt: at)
        #expect(decision == .accept)
        let p = try #require(payload)
        #expect(p.body == "Purchase of AED 45.10 with Credit Card ending 1234 at CARREFOUR")
        #expect(p.sender == "FAB")
        #expect(p.receivedAt == at)

        let (_, other) = SMSCapture.payload(body: p.body, sender: "FAB", receivedAt: at)
        #expect(other?.clientMsgId != p.clientMsgId)
    }

    @Test("the ingest payload is the jsonb element ingest_sms expects, lowercase UUID")
    func jsonShape() throws {
        let id = UUID(uuidString: "6F1C2A8E-8A0B-4F7E-9D61-2C1F6A3B9E10")!
        let p = SMSPayload(clientMsgId: id, receivedAt: Date(timeIntervalSince1970: 1_791_436_364), sender: "FAB", body: "AED 1")
        let data = try JSONEncoder().encode(p.json)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == [
            "client_msg_id": "6f1c2a8e-8a0b-4f7e-9d61-2c1f6a3b9e10",
            "received_at": "2026-10-08T05:12:44.000Z",
            "sender": "FAB",
            "body": "AED 1",
        ])
    }

    @Test("dialogs never echo the message")
    func dialogsDoNotEcho() {
        let body = "Purchase of AED 45.10 with Credit Card ending 1234 at CARREFOUR"
        let outcomes: [SMSIntakeOutcome] = [
            .dropped(.dropOTP), .dropped(.dropEmpty), .queued(.noLedger),
            .delivered(status: "new"), .delivered(status: "unknown_card"), .queued(.offline), .queued(.signedOut),
            .parked(reason: "Ledger rejected this message (invalid)."), .failed("x"),
        ]
        for outcome in outcomes {
            #expect(!outcome.dialog(ledger: "Personal").contains("CARREFOUR"))
            #expect(!outcome.dialog().contains("1234"))
            #expect(!SensitiveText.looksLikeSMS(outcome.telemetryOutcome))
            _ = body
        }
    }
}
