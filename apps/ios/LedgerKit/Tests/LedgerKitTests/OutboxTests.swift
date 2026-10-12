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
        #expect(entries[0].sms?.body.contains("AED 1.00") == true)
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
        // A server outage; being offline is not an attempt (OutboxOfflineTests).
        let api = StubAPI(.fail(.server(status: 503, code: nil, message: "Service Unavailable")))
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
        #expect(entry.lastError == "Service Unavailable")

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
    static let personal = SMSTarget(profileCode: "prf_01hzy3k8w9m2n4p6q8r0s2t4v6", name: "Personal")

    func intake(_ api: StubAPI, target: SMSTarget? = SMSIntakeTests.personal, url: URL = temporaryOutboxURL(),
                log: CaptureLog? = nil) -> (SMSIntake, Outbox) {
        let outbox = Outbox(fileURL: url, api: api)
        return (SMSIntake(outbox: outbox, target: { target }, log: log), outbox)
    }

    @Test("online: filtered, enqueued, delivered to the SMS ledger, and the outbox is empty after")
    func delivered() async throws {
        let api = StubAPI(.succeed(status: "created"))
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .delivered(status: "created"))
        #expect(dialog == "Logged to Personal.")
        #expect(api.calls.count == 1)
        #expect(api.calls[0].profile == Self.personal.profileCode)
        #expect(api.calls[0].messages[0].body == card)
        #expect(api.calls[0].messages[0].sender == "FAB")
        #expect(await outbox.status().isEmpty)
    }

    @Test("offline: the message stays in the outbox and the dialog says why")
    func queuedOffline() async throws {
        let api = StubAPI(.fail(.network("-1009")))
        let url = temporaryOutboxURL()
        let (intake, _) = intake(api, url: url)
        let (outcome, dialog) = await intake.handle(body: card, sender: nil)
        #expect(outcome == .queued(.offline))
        #expect(dialog == "Saved on this phone. It will be sent to Personal when you're back online.")

        // The app later flushes the same file with the same client_msg_id.
        let appOutbox = Outbox(fileURL: url, api: StubAPI(.succeed(status: "linked")))
        let entries = try await appOutbox.entries()
        #expect(entries.count == 1)
        let report = await appOutbox.flush(force: true)
        #expect(report.results.first?.clientMsgId == entries[0].id.uuidString.lowercased())
    }

    @Test("signed out and server errors are not reported as 'offline'")
    func honestQueueReasons() async {
        let (signedOut, _) = intake(StubAPI(.fail(.notSignedIn)))
        let a = await signedOut.handle(body: card, sender: "FAB")
        #expect(a.outcome == .queued(.signedOut))
        #expect(a.dialog.contains("signed out"))
        let (busy, _) = intake(StubAPI(.fail(.server(status: 503, code: nil, message: "Service Unavailable"))))
        let b = await busy.handle(body: card, sender: "FAB")
        #expect(b.outcome == .queued(.serverUnavailable))
        #expect(!b.dialog.contains("online"))
    }

    @Test("a viewer's ledger (42501) parks the message and says so — it is never 'saved for later'")
    func permissionParks() async {
        let api = StubAPI(.fail(.server(status: nil, code: "42501", message: "not an owner of profile")))
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(body: card, sender: "FAB")
        guard case .parked = outcome else {
            Issue.record("expected parked, got \(outcome)")
            return
        }
        #expect(dialog.contains("only its owners"))
        #expect(dialog.contains("Settings"))
        #expect(await outbox.status().parked == 1)
        #expect(await outbox.status().pending == 0)
    }

    @Test("a per-message 'invalid' status (new server) parks with the server's reason")
    func invalidStatusParks() async {
        let api = StubAPI(.custom { _, messages in
            messages.map { SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: nil,
                                           status: "invalid", txnCode: nil, reason: "body too long") }
        })
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .parked(reason: "Ledger rejected this message: body too long"))
        #expect(dialog.hasPrefix("Not logged."))
        #expect(await outbox.parkedEntries().first?.parkedReason == "Ledger rejected this message: body too long")
    }

    @Test("OTPs and empty input never reach the API or the outbox", arguments: [
        "Your OTP for AED 250.00 on Credit Card ending 1234 is 482913",
        "  \n ",
    ])
    func dropped(body: String) async throws {
        let api = StubAPI()
        let (intake, outbox) = intake(api)
        let (outcome, _) = await intake.handle(body: body, sender: "FAB")
        guard case .dropped = outcome else {
            Issue.record("expected a drop, got \(outcome)")
            return
        }
        #expect(api.calls.isEmpty)
        #expect(await outbox.status().isEmpty)
    }

    @Test("a debit-card alert is sent; the server files it as ignored")
    func debitSent() async throws {
        let api = StubAPI(.succeed(status: "ignored"))
        let (intake, outbox) = intake(api)
        let (outcome, dialog) = await intake.handle(body: "Your Debit Card ending 1234 was used for AED 45.00 at ENOC",
                                                    sender: "FAB")
        #expect(outcome == .delivered(status: "ignored"))
        #expect(dialog == "Logged to Personal as not a card purchase.")
        #expect(api.calls.count == 1)
        #expect(await outbox.status().isEmpty)
    }

    @Test("no SMS ledger set: the message is saved without one, nothing is sent, the dialog says where to set it")
    func noLedgerIsSaved() async throws {
        let api = StubAPI()
        let url = temporaryOutboxURL()
        let (intake, outbox) = intake(api, target: nil, url: url)
        let (outcome, dialog) = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .queued(.noLedger))
        #expect(outcome.needsAttention)
        #expect(dialog.contains("SMS go to") && !dialog.contains("iPhone"))
        #expect(api.calls.isEmpty)
        let entry = try #require(try await outbox.entries().first)
        #expect(entry.profileCode == nil && entry.awaitsLedger)
        let status = await outbox.status()
        #expect(status.awaitingLedger == 1 && status.pending == 0 && status.waiting == 1)
        #expect(status.summary == "1 message waiting")
        #expect(OutboxSync.plan(status) == nil)   // nothing iOS could send in the background

        // A flush with no ledger known still sends nothing.
        await outbox.flush(force: true)
        #expect(api.calls.isEmpty)

        // Once the "SMS go to" ledger is known, the next flush (the app's) files it there.
        let app = Outbox(fileURL: url, api: api, pendingTarget: { Self.personal.profileCode })
        let report = await app.flush()
        #expect(report.sent == 1)
        #expect(api.calls.map(\.profile) == [Self.personal.profileCode])
        #expect(api.calls[0].messages[0].clientMsgId == entry.id)
        #expect(await app.status().isEmpty)
    }

    @Test("adopting pending entries leaves entries that already have a ledger alone")
    func adoptOnlyPending() async throws {
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI())
        try await outbox.enqueue(SMSPayload(receivedAt: Date(), sender: "FAB", body: card), profileCode: nil)
        try await outbox.enqueue(SMSPayload(receivedAt: Date(), sender: "FAB", body: card), profileCode: "prf_old")
        #expect(try await outbox.adoptPending(profileCode: "prf_new") == 1)
        #expect(try await outbox.entries().map(\.profileCode).sorted { ($0 ?? "") < ($1 ?? "") } == ["prf_new", "prf_old"])
    }

    @Test("server statuses map to short dialogs that point at Review")
    func statusDialogs() async {
        let api = StubAPI(.succeed(status: "unknown_card"))
        let (intake, _) = intake(api)
        let (outcome, dialog) = await intake.handle(body: card, sender: "FAB")
        #expect(outcome == .delivered(status: "unknown_card"))
        #expect(dialog.contains("doesn't know this card"))
        #expect(dialog.contains("Needs review"))
        #expect(SMSIntakeOutcome.delivered(status: "duplicate_delivery").dialog() == "Already logged.")
        #expect(SMSIntakeOutcome.delivered(status: "held").dialog(ledger: "Home").contains("Needs review"))
    }

    @Test("every run records the last capture (outcome only, never the message)")
    func lastCapture() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-tests-\(UUID().uuidString)"))
        let log = CaptureLog(defaults: defaults)
        let (intake, _) = intake(StubAPI(.succeed(status: "created")), log: log)
        _ = await intake.handle(body: card, sender: "FAB")
        let last = try #require(log.last)
        #expect(last.outcome == "delivered_created")
        #expect(last.message == "Logged to Personal.")
        #expect(!last.message.contains("CARREFOUR"))
        #expect(last.sender == "FAB")
        #expect(last.length == card.count)
        #expect(last.input == "FAB · \(card.count) characters")
        #expect(log.lastTest == nil)
    }

    @Test("Recent captures keeps the last 20 real runs, newest first, never the text")
    func recentCaptures() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-tests-\(UUID().uuidString)"))
        let log = CaptureLog(defaults: defaults)
        let (intake, _) = intake(StubAPI(.succeed(status: "created")), log: log)
        _ = await intake.handle(body: "EmiratesNBD", sender: nil)
        for _ in 0..<CaptureLog.recentLimit { _ = await intake.handle(body: card, sender: "FAB") }
        _ = await intake.selfTest()
        let recent = log.recent
        #expect(recent.count == CaptureLog.recentLimit)
        #expect(recent.allSatisfy { !$0.isTest && $0.sender == "FAB" })   // the oldest fell off; tests never enter
        _ = await intake.handle(body: "EmiratesNBD", sender: "  ")
        #expect(log.recent.first?.input == "No sender · 11 characters")
        let stored = try #require(defaults.data(forKey: CaptureLog.recentKey))
        #expect(!String(decoding: stored, as: UTF8.self).contains("CARREFOUR"))
        log.clear()
        #expect(log.recent.isEmpty)
    }

    @Test("Send test: a synthetic one-time passcode is dropped on the phone; nothing is sent")
    func selfTest() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-tests-\(UUID().uuidString)"))
        let log = CaptureLog(defaults: defaults)
        let api = StubAPI()
        let (subject, _) = intake(api, log: log)
        #expect(SMSCapture.classify(body: SMSSelfTest.message) == .dropOTP)
        let result = await subject.selfTest()
        #expect(result.passed)
        #expect(result.message.contains("files card alerts in Personal"))
        #expect(api.calls.isEmpty)
        #expect(log.lastTest?.isTest == true)
        #expect(log.last == nil)   // a test never overwrites "Last captured"

        let (noTarget, _) = intake(api, target: nil, log: log)
        #expect(await noTarget.selfTest().passed == false)
        let (signedOut, outbox) = intake(StubAPI(.fail(.notSignedIn)), log: log)
        try await outbox.enqueue(SMSPayload(receivedAt: Date(), sender: "FAB", body: card), profileCode: "prf_x")
        let failed = await signedOut.selfTest()
        #expect(!failed.passed)
        #expect(failed.message.contains("signed out"))
    }
}
