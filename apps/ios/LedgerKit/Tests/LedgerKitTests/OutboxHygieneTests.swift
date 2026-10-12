import Foundation
import Testing
@testable import LedgerKit

/// BACKLOG IOS-12r: a stuck outbox shows outside Settings, and sign-out
/// deletes what is waiting on the phone only after a confirmation naming it.
@Suite("Outbox hygiene — stale alert, sign-out cleanup")
struct OutboxHygieneTests {
    let card = "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE"

    func payload(_ n: Int) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB", body: card)
    }

    @Test("a message is stale an hour after capture, whatever kept it: no badge or strip before that")
    func staleAfterAnHour() async throws {
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(.fail(.network("-1009"))),
                            now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: "prf_a")
        await outbox.flush()
        clock.advance(59 * 60)
        var status = await outbox.status()
        #expect(status.stale == 0 && status.badgeCount == 0 && status.staleAlert == nil)

        clock.advance(60)
        status = await outbox.status()
        #expect(status.badgeCount == 1)
        #expect(status.staleAlert == StaleOutboxAlert(
            title: "1 SMS hasn't reached Bank Ledger",
            detail: "Waiting for over an hour. Open Settings to send it now."))

        try await outbox.enqueue(payload(2), profileCode: nil)   // fresh, no ledger: not stale yet
        status = await outbox.status()
        #expect(status.stale == 1 && status.waiting == 2)
        clock.advance(3600)
        status = await outbox.status()
        #expect(status.staleAlert?.title == "2 SMS haven't reached Bank Ledger")
        #expect(status.staleAlert?.detail == "No ledger was set for SMS when they arrived. Open Settings → SMS.")
        #expect(status.awaitingLedgerNote?.hasPrefix("1 item arrived while no ledger was set") == true)
    }

    @Test("stuck card payments are named as such in the strip and count in the badge")
    func stalePayments() async throws {
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(), now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: nil)
        let payment = try WalletCapture.payment(amount: LedgerDecimal.parse("45.10")!, currency: "AED", merchant: "Shop",
                                                passName: "Wio", occurredAt: clock.now, clientMsgId: UUID()).get()
        try await outbox.enqueue(payment, profileCode: nil)
        clock.advance(2 * 3600)
        let status = await outbox.status()
        #expect(status.badgeCount == 2 && status.awaitingLedger == 2)
        #expect(status.staleAlert?.title == "1 SMS and 1 card payment haven't reached Bank Ledger")
        #expect(OutboxStatus(stale: 1, stalePayments: 1).staleAlert?.title == "1 card payment hasn't reached Bank Ledger")
    }

    @Test("a parked message counts once it is an hour old and points at Retry / Delete")
    func parkedStale() {
        let status = OutboxStatus(pending: 0, parked: 2, stale: 2)
        #expect(status.staleAlert?.detail == "Stopped retrying. Open Settings to retry or delete them.")
        #expect(status.summary == "2 messages not sent")
    }

    @Test("the sign-out warning names what would be deleted, and is nil when nothing would be")
    func signOutWarning() {
        #expect(DeviceQueue(messages: 0, pdfs: 0).signOutWarning == nil)
        #expect(DeviceQueue(messages: 1, pdfs: 0).signOutWarning
                == "1 SMS hasn't reached Bank Ledger. Signing out deletes it from this phone.")
        #expect(DeviceQueue(messages: 2, pdfs: 1).signOutWarning
                == "2 SMS and 1 PDF haven't reached Bank Ledger. Signing out deletes them from this phone.")
        #expect(DeviceQueue(messages: 0, pdfs: 3).signOutWarning
                == "3 PDFs haven't reached Bank Ledger. Signing out deletes them from this phone.")
        #expect(DeviceQueue(messages: 2, payments: 1, pdfs: 1).signOutWarning
                == "2 SMS, 1 card payment and 1 PDF haven't reached Bank Ledger. Signing out deletes them from this phone.")
        #expect(DeviceQueue(messages: 0, payments: 2, pdfs: 0).signOutWarning
                == "2 card payments haven't reached Bank Ledger. Signing out deletes them from this phone.")
    }

    @Test("sign-out cleanup: the outbox and every saved PDF (waiting or refused) go")
    func cleanup() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-signout-\(UUID().uuidString)")
        let pending = PendingUploads(container: container)
        try pending.save(UploadFile(filename: "a.pdf", data: Data("%PDF-1".utf8)))
        try pending.save(UploadFile(filename: "b.pdf", data: Data("%PDF-1".utf8)))
        pending.quarantine(try #require(pending.list().first), reason: "Too large.")
        #expect(pending.count == 1 && pending.rejected().count == 1)
        pending.removeAll()
        #expect(pending.count == 0 && pending.rejected().isEmpty)

        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI())
        try await outbox.enqueue([payload(1), payload(2)], profileCode: nil)
        try await outbox.removeAll()
        #expect(await outbox.status().isEmpty)
    }

    @Test("an outbox file written before IOS-12r (every entry has a ledger) still decodes")
    func oldFileDecodes() async throws {
        let url = temporaryOutboxURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = """
        [{"payload":{"client_msg_id":"6f1c2a8e-8a0b-4f7e-9d61-2c1f6a3b9e10","received_at":"2026-10-08T05:12:44.000Z",
        "sender":"FAB","body":"AED 1"},"profile_code":"prf_a","enqueued_at":"2026-10-08T05:12:44.000Z","attempts":0,
        "next_attempt_at":"2026-10-08T05:12:44.000Z"}]
        """
        try Data(old.utf8).write(to: url)
        let entries = try await Outbox(fileURL: url, api: StubAPI()).entries()
        #expect(entries.map(\.profileCode) == ["prf_a"])
        #expect(entries.allSatisfy { !$0.awaitsLedger })
    }
}
