import Foundation
import Testing
@testable import LedgerKit

@Suite("Log Card Payment — the intent's path, offline queue shared with SMS")
struct WalletIntakeTests {
    let personal = SMSTarget(profileCode: "prf_personal", name: "Personal")
    let offline = LedgerAPIError.network(String(URLError.Code.notConnectedToInternet.rawValue))
    let amount = LedgerDecimal.parse("45.10")!

    func intake(_ api: StubAPI, target: SMSTarget?? = .none) -> (WalletIntake, Outbox) {
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        let resolved: SMSTarget? = target ?? personal
        return (WalletIntake(outbox: outbox, target: { resolved }), outbox)
    }

    func sms(_ n: Int) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB",
                   body: "Purchase of AED \(n).00 with Credit Card ending 1234")
    }

    @Test("online: sent to ingest_wallet_transactions at once, nothing left waiting")
    func delivered() async throws {
        let api = StubAPI(.succeed(status: "created"))
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(amount: amount, currency: "aed", merchant: "Carrefour", card: "Wio")
        #expect(outcome == .delivered(status: "created"))
        #expect(dialog == "Logged to Personal.")
        #expect(api.calls.isEmpty)
        let call = try #require(api.walletCalls.first)
        #expect(call.profile == "prf_personal")
        #expect(call.items.first?.currency == "AED")
        #expect(call.items.first?.amount == amount)
        #expect(await outbox.status().isEmpty)
    }

    @Test("offline at the till: queued, then flushed with waiting SMS, each to its own RPC")
    func queuedThenFlushed() async throws {
        let api = StubAPI(.fail(offline))
        let (intake, outbox) = intake(api)
        try await outbox.enqueue(sms(1), profileCode: "prf_personal")
        let (outcome, dialog) = await intake.handle(amount: amount, currency: "AED", merchant: "Carrefour", card: "Wio")
        #expect(outcome == .queued(.offline))
        #expect(dialog.contains("back online"))
        let waiting = try await outbox.entries()
        #expect(waiting.map(\.kind).sorted() == [.sms, .wallet])
        #expect(waiting.allSatisfy { $0.attempts == 0 })

        api.behaviour = .succeed(status: "created")
        let report = await outbox.flush(force: true)
        #expect(report.sent == 2)
        #expect(report.remaining == 0)
        #expect(api.calls.last?.messages.count == 1)
        #expect(api.walletCalls.last?.items.count == 1)
        #expect(await outbox.status().isEmpty)
    }

    @Test("unknown card: the dialog names the card and points to Settings")
    func unknownCard() async {
        let api = StubAPI(.succeed(status: "unknown_card"))
        let (intake, _) = intake(api)
        let (outcome, dialog) = await intake.handle(amount: amount, currency: "AED", merchant: "Carrefour",
                                                    card: " Wio  Credit ")
        #expect(outcome == .delivered(status: "unknown_card"))
        #expect(outcome.needsAttention)
        #expect(dialog.contains("“Wio Credit”"))
        #expect(dialog.contains("Card names"))
        #expect(!dialog.contains("Carrefour"))
    }

    @Test("statuses reuse the SMS wording", arguments: [
        ("duplicate_delivery", "Already logged."),
        ("duplicate", "Logged to Personal."),
        ("held", "Needs review"),
    ])
    func statuses(status: String, expected: String) async {
        let (intake, _) = intake(StubAPI(.succeed(status: status)))
        let (_, dialog) = await intake.handle(amount: amount, currency: "AED", merchant: "Shop", card: "Wio")
        #expect(dialog.contains(expected))
    }

    @Test("a refused payment never reaches the API or the outbox")
    func refused() async {
        let api = StubAPI()
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(amount: 0, currency: "AED", merchant: "Shop", card: "Wio")
        #expect(outcome == .refused(code: "invalid_amount", message: WalletCapture.Problem.invalidAmount.userMessage))
        #expect(outcome.telemetryOutcome == "refused_invalid_amount")
        #expect(dialog.hasPrefix("Not logged"))
        #expect(api.walletCalls.isEmpty)
        #expect(await outbox.status().isEmpty)
    }

    @Test("no ledger set: saved without one (like an SMS), nothing sent, sent once the ledger is known (IOS-12r)")
    func noLedgerIsSaved() async throws {
        let api = StubAPI(.succeed(status: "created"))
        let (intake, outbox) = intake(api, target: .some(nil))
        let (outcome, dialog) = await intake.handle(amount: amount, currency: "AED", merchant: "Shop", card: "Wio")
        #expect(outcome == .queued(.noLedger) && outcome.needsAttention)
        #expect(dialog.contains("SMS go to") && dialog.hasPrefix("Saved on this phone") && !dialog.contains("iPhone"))
        #expect(api.walletCalls.isEmpty)
        let status = await outbox.status()
        #expect(status.awaitingLedger == 1 && status.pending == 0)
        let entry = try #require(try await outbox.entries().first)
        #expect(entry.kind == .wallet && entry.profileCode == nil)
        #expect(try await outbox.adoptPending(profileCode: "prf_personal", userID: nil) == 1)
        await outbox.flush()
        #expect(api.walletCalls.map(\.profile) == ["prf_personal"])
        #expect(await outbox.status().isEmpty)
    }

    @Test("a per-item 'invalid' parks the payment with the reason in words")
    func invalidParks() async {
        let api = StubAPI()
        api.walletDecide = { _, items in
            items.map { SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: nil,
                                        status: "invalid", txnCode: nil, reason: "invalid_pass_name") }
        }
        let (intake, outbox) = intake(api)
        let (outcome, _) = await intake.handle(amount: amount, currency: "AED", merchant: "Shop", card: "Wio")
        #expect(outcome == .parked(reason: "Ledger rejected this message: its card name is empty or longer than 64 characters."))
        let parked = await outbox.parkedEntries()
        #expect(parked.first?.wallet?.passName == "Wio")
    }

    @Test("the outbox file keeps the kind; SMS entries without one (older files) still decode")
    func persistedFormat() async throws {
        let api = StubAPI(.fail(offline))
        let (intake, outbox) = intake(api)
        _ = await intake.handle(amount: amount, currency: "AED", merchant: "Shop", card: "Wio")
        let entry = try #require(try await outbox.entries().first)
        let json = String(decoding: try LedgerJSON.makeEncoder().encode([entry]), as: UTF8.self)
        #expect(json.contains(#""kind":"wallet""#))
        #expect(json.contains(#""amount":"45.1""#))
        let back = try LedgerJSON.decode([OutboxEntry].self, from: Data(json.utf8))
        #expect(back == [entry])
    }
}
