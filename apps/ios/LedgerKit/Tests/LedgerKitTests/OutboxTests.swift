import Foundation
import Testing
@testable import LedgerKit

@Suite("Outbox — App Group file queue with backoff")
struct OutboxTests {
    let profile = "prf_01hzy3k8w9m2n4p6q8r0s2t4v6"

    func payload(_ n: Int) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB",
                   body: "Purchase of AED \(n).00 with Credit Card ending 1234")
    }

    @Test("entries persist across Outbox instances (another process sees them)")
    func persists() async throws {
        let url = temporaryOutboxURL()
        let first = Outbox(fileURL: url, api: StubAPI())
        try await first.enqueue(payload(1), profileCode: profile)
        try await first.enqueue(payload(2), profileCode: profile)

        let second = Outbox(fileURL: url, api: StubAPI())
        let entries = try await second.entries()
        #expect(entries.count == 2)
        #expect(entries[0].payload.body.contains("AED 1.00"))
        #expect(entries[0].profileCode == profile)
        #expect(await second.status().pending == 2)
    }

    @Test("enqueue is idempotent on client_msg_id")
    func idempotentEnqueue() async throws {
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI())
        let p = payload(1)
        try await outbox.enqueue(p, profileCode: profile)
        try await outbox.enqueue(p, profileCode: profile)
        #expect(try await outbox.entries().count == 1)
    }

    @Test("a successful flush sends oldest first and empties the queue")
    func flushSuccess() async throws {
        let api = StubAPI(.succeed(status: "new"))
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue(payload(2), profileCode: profile)
        try await outbox.enqueue(payload(1), profileCode: profile)

        let report = await outbox.flush()
        #expect(report.sent == 2)
        #expect(report.remaining == 0)
        #expect(report.results.allSatisfy { $0.status == "new" })
        #expect(api.calls.count == 1)
        #expect(api.calls[0].profile == profile)
        #expect(await outbox.status().isEmpty)
    }

    @Test("a failed flush keeps entries and backs off exponentially")
    func backoff() async throws {
        let api = StubAPI(.fail(.network("-1009")))
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api, backoff: Backoff(base: 30, cap: 3600),
                            now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: profile)

        var report = await outbox.flush()
        #expect(report.failed == 1)
        #expect(report.remaining == 1)
        var entry = try #require(try await outbox.entries().first)
        #expect(entry.attempts == 1)
        #expect(entry.nextAttemptAt == clock.now.addingTimeInterval(30))
        #expect(entry.lastError == "No connection to Ledger.")

        // Not due yet: nothing is sent.
        clock.advance(10)
        report = await outbox.flush()
        #expect(report.sent == 0 && report.failed == 0)
        #expect(api.calls.count == 1)

        // Due again: second failure doubles the delay.
        clock.advance(25)
        await outbox.flush()
        entry = try #require(try await outbox.entries().first)
        #expect(entry.attempts == 2)
        #expect(entry.nextAttemptAt == clock.now.addingTimeInterval(60))

        // Back online: force-flush ignores the backoff and delivers.
        api.behaviour = .succeed(status: "matched")
        report = await outbox.flush(force: true)
        #expect(report.sent == 1)
        #expect(await outbox.status().isEmpty)
    }

    @Test("backoff is capped")
    func backoffCap() {
        let b = Backoff(base: 30, cap: 3600)
        #expect(b.delay(afterAttempt: 1) == 30)
        #expect(b.delay(afterAttempt: 2) == 60)
        #expect(b.delay(afterAttempt: 5) == 480)
        #expect(b.delay(afterAttempt: 50) == 3600)
    }

    @Test("signed out stops the flush — every later batch would fail the same way")
    func stopsWhenSignedOut() async throws {
        let api = StubAPI(.fail(.notSignedIn))
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue(payload(1), profileCode: "prf_a")
        try await outbox.enqueue(payload(2), profileCode: "prf_b")
        let report = await outbox.flush()
        #expect(api.calls.count == 1)
        #expect(report.error == .notSignedIn)
        #expect(report.remaining == 2)
    }

    @Test("more than 200 messages go in batches of 200, grouped by profile")
    func batching() async throws {
        let api = StubAPI()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue((0..<205).map(payload), profileCode: profile)
        try await outbox.enqueue(payload(999), profileCode: "prf_other")
        let report = await outbox.flush()
        #expect(report.sent == 206)
        #expect(api.calls.map(\.messages.count).sorted() == [1, 5, 200])
        #expect(api.sentMessageCount == 206)
    }

    @Test("an entry enqueued while a flush is in flight is not lost")
    func concurrentEnqueue() async throws {
        let url = temporaryOutboxURL()
        let api = StubAPI()
        let app = Outbox(fileURL: url, api: api)
        let intent = Outbox(fileURL: url, api: api)    // a second process
        try await app.enqueue(payload(1), profileCode: profile)
        async let flushed = app.flush()
        try await intent.enqueue(payload(2), profileCode: profile)
        _ = await flushed
        await app.flush()
        #expect(try await app.entries().isEmpty)
        let sent = Set(api.calls.flatMap(\.messages).map(\.clientMsgId))
        #expect(sent.count == 2)
    }

    @Test("removeAll clears the queue")
    func clear() async throws {
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI())
        try await outbox.enqueue(payload(1), profileCode: profile)
        try await outbox.removeAll()
        #expect(await outbox.status().summary == "Nothing waiting")
    }
}

@Suite("Log Bank SMS — the App Intent's path, with a stub API")
struct SMSIntakeTests {
    let card = "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE"

    func intake(_ api: StubAPI, profile: String? = "prf_01hzy3k8w9m2n4p6q8r0s2t4v6", url: URL = temporaryOutboxURL()) -> (SMSIntake, Outbox) {
        let outbox = Outbox(fileURL: url, api: api)
        return (SMSIntake(outbox: outbox, profileCode: { profile }), outbox)
    }

    @Test("online: filtered, enqueued, delivered, and the outbox is empty after")
    func delivered() async throws {
        let api = StubAPI(.succeed(status: "new"))
        let (intake, outbox) = intake(api)
        let outcome = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .delivered(status: "new"))
        #expect(outcome.dialog == "Logged to Ledger.")
        #expect(api.calls.count == 1)
        #expect(api.calls[0].messages[0].body == card)
        #expect(api.calls[0].messages[0].sender == "FAB")
        #expect(await outbox.status().isEmpty)
    }

    @Test("offline: the message stays in the outbox and the dialog says so")
    func queuedOffline() async throws {
        let api = StubAPI(.fail(.network("-1009")))
        let url = temporaryOutboxURL()
        let (intake, _) = intake(api, url: url)
        let outcome = await intake.handle(body: card, sender: nil)
        #expect(outcome == .queued(pending: 1))
        #expect(outcome.dialog.contains("Saved"))

        // The app later flushes the same file with the same client_msg_id.
        let appOutbox = Outbox(fileURL: url, api: StubAPI(.succeed(status: "matched")))
        let entries = try await appOutbox.entries()
        #expect(entries.count == 1)
        let report = await appOutbox.flush(force: true)
        #expect(report.results.first?.clientMsgId == entries[0].payload.clientMsgId.uuidString.lowercased())
    }

    @Test("OTP and debit alerts never reach the API or the outbox", arguments: [
        "Your OTP for AED 250.00 on Credit Card ending 1234 is 482913",
        "Your Debit Card ending 1234 was used for AED 45.00 at ENOC",
    ])
    func dropped(body: String) async throws {
        let api = StubAPI()
        let (intake, outbox) = intake(api)
        let outcome = await intake.handle(body: body, sender: "FAB")
        guard case .dropped = outcome else {
            Issue.record("expected a drop, got \(outcome)")
            return
        }
        #expect(api.calls.isEmpty)
        #expect(await outbox.status().isEmpty)
    }

    @Test("no profile selected (never signed in): nothing is sent")
    func noProfile() async {
        let api = StubAPI()
        let (intake, _) = intake(api, profile: nil)
        #expect(await intake.handle(body: card, sender: "FAB") == .noProfile)
        #expect(api.calls.isEmpty)
    }

    @Test("server statuses map to short dialogs")
    func statusDialogs() async {
        let api = StubAPI(.succeed(status: "unknown_card"))
        let (intake, _) = intake(api)
        let outcome = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .delivered(status: "unknown_card"))
        #expect(outcome.dialog.contains("doesn't know this card"))
        #expect(SMSIntakeOutcome.delivered(status: "duplicate_delivery").dialog == "Already logged.")
    }
}
