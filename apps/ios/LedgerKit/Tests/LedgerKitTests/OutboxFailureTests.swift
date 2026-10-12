import Foundation
import Testing
@testable import LedgerKit

@Suite("Outbox — permanent vs transient failures never wedge the queue")
struct OutboxFailureTests {
    let mine = "prf_mine"
    let shared = "prf_shared"

    func payload(_ n: Int, body: String? = nil) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB",
                   body: body ?? "Purchase of AED \(n).00 with Credit Card ending 1234")
    }

    static func ok(_ messages: [SMSPayload], status: String = "created") -> [SMSIngestResult] {
        messages.map { SMSIngestResult(clientMsgId: $0.clientMsgId.uuidString.lowercased(), smsCode: "sms_x",
                                       status: status, txnCode: nil) }
    }

    @Test("error classification: SQLSTATE and HTTP status")
    func classification() {
        typealias E = LedgerAPIError
        #expect(E.server(status: nil, code: "42501", message: "x").kind == .permanent)
        #expect(E.server(status: nil, code: "42501", message: "x").isPermission)
        #expect(E.server(status: nil, code: "22023", message: "x").kind == .permanent)
        #expect(E.server(status: nil, code: "23505", message: "x").kind == .permanent)
        #expect(E.server(status: nil, code: "P0001", message: "x").kind == .permanent)
        #expect(E.server(status: nil, code: "PGRST202", message: "x").kind == .permanent)
        #expect(E.server(status: nil, code: "PGRST003", message: "x").kind == .transient)
        #expect(E.server(status: nil, code: "PGRST301", message: "x").kind == .signedOut)
        #expect(E.server(status: nil, code: "57014", message: "statement timeout").kind == .transient)
        #expect(E.server(status: nil, code: "08006", message: "x").kind == .transient)
        #expect(E.server(status: nil, code: "40001", message: "x").kind == .transient)
        #expect(E.server(status: 503, code: nil, message: "x").kind == .transient)
        #expect(E.server(status: 429, code: nil, message: "x").kind == .transient)
        #expect(E.server(status: 422, code: "NOT_A_PDF", message: "x").kind == .permanent)
        #expect(E.server(status: 403, code: "FORBIDDEN", message: "x").isPermission)
        #expect(E.server(status: 401, code: nil, message: "x").kind == .signedOut)
        #expect(E.server(status: nil, code: nil, message: "x").kind == .transient)
        #expect(E.network("-1009").kind == .transient)
        #expect(E.notSignedIn.kind == .signedOut)
        #expect(E.server(status: nil, code: "42501", message: "permission denied for table profiles").description
                .contains("only owners"))
    }

    @Test("one invalid message (old server: whole batch fails 22023) is isolated; the rest are delivered")
    func bisectsPermanentFailure() async throws {
        let poison = "Purchase of AED 13.00 with Credit Card ending 1234 POISON"
        let api = StubAPI(.custom { _, messages in
            if messages.contains(where: { $0.body.contains("POISON") }) {
                throw LedgerAPIError.server(status: nil, code: "22023", message: "invalid input syntax for type date")
            }
            return Self.ok(messages)
        })
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue((0..<10).map { $0 == 3 ? payload($0, body: poison) : payload($0) }, profileCode: mine)

        let report = await outbox.flush()
        #expect(report.sent == 9)
        #expect(report.parked.count == 1)
        let status = await outbox.status()
        #expect(status.pending == 0)
        #expect(status.parked == 1)
        let parked = try #require(await outbox.parkedEntries().first)
        #expect(parked.sms?.body == poison)
        #expect(parked.parkedReason?.contains("invalid input syntax") == true)

        // New messages are no longer batched with the poison one.
        try await outbox.enqueue(payload(42), profileCode: mine)
        let next = await outbox.flush()
        #expect(next.sent == 1)
        #expect(api.calls.last?.messages.count == 1)
        #expect(await outbox.status().pending == 0)
    }

    @Test("a viewer ledger (42501) parks that profile's messages without blocking another profile")
    func permissionDoesNotBlockOthers() async throws {
        let api = StubAPI(.custom { profile, messages in
            if profile == "prf_shared" {
                throw LedgerAPIError.server(status: nil, code: "42501", message: "not an owner")
            }
            return Self.ok(messages)
        })
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: shared)
        try await outbox.enqueue([payload(3)], profileCode: mine)

        let report = await outbox.flush()
        #expect(report.sent == 1)
        #expect(report.parked.count == 2)
        // One call per profile: a permission error is not bisected.
        #expect(api.calls.filter { $0.profile == shared }.count == 1)
        #expect(await outbox.status() == OutboxStatus(pending: 0, parked: 2, oldest: nil, nextAttemptAt: nil, lastError: nil))
    }

    @Test("transient failures are capped: after maxAttempts (8) the entry is parked")
    func attemptCap() async throws {
        let api = StubAPI(.fail(.server(status: 503, code: nil, message: "Service Unavailable")))
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api, now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: mine)
        for _ in 1..<Outbox.maxAttempts {
            await outbox.flush(force: true)
        }
        #expect(await outbox.status().pending == 1)
        let last = await outbox.flush(force: true)
        #expect(last.parked.count == 1)
        #expect(await outbox.status().pending == 0)
        #expect(await outbox.parkedEntries().first?.parkedReason?.hasPrefix("Gave up after 8 tries") == true)
        // Parked entries are not sent again, even forced.
        let calls = api.calls.count
        await outbox.flush(force: true)
        #expect(api.calls.count == calls)
    }

    @Test("signed out does not use up attempts")
    func signedOutNotCounted() async throws {
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(.fail(.notSignedIn)))
        try await outbox.enqueue(payload(1), profileCode: mine)
        for _ in 0..<(Outbox.maxAttempts + 2) { await outbox.flush(force: true) }
        let entry = try #require(try await outbox.entries().first)
        #expect(entry.attempts == 0)
        #expect(!entry.isParked)
    }

    @Test("Retry puts a parked message back, optionally into the current SMS ledger; Delete removes it")
    func retryAndDelete() async throws {
        let api = StubAPI(.fail(.server(status: nil, code: "42501", message: "not an owner")))
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: shared)
        await outbox.flush()
        let parked = await outbox.parkedEntries()
        #expect(parked.count == 2)

        api.behaviour = .custom { _, messages in Self.ok(messages) }
        try await outbox.retry([parked[0].id], reassignTo: mine)
        let report = await outbox.flush()
        #expect(report.sent == 1)
        #expect(api.calls.last?.profile == mine)

        try await outbox.remove([parked[1].id])
        #expect(await outbox.status().isEmpty)
    }

    @Test("an entry the server did not answer for stays queued and counts an attempt")
    func unansweredEntry() async throws {
        let api = StubAPI(.custom { _, messages in Self.ok(Array(messages.dropLast())) })
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: mine)
        let report = await outbox.flush()
        #expect(report.sent == 1)
        let left = try await outbox.entries()
        #expect(left.count == 1)
        #expect(left[0].attempts == 1)
        #expect(!left[0].isParked)
    }

    @Test("files written before parking existed still decode")
    func legacyFile() async throws {
        let url = temporaryOutboxURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
        [{"attempts":3,"enqueued_at":"2026-10-08T05:12:44.000Z","last_error":"No connection to Ledger.",
          "next_attempt_at":"2026-10-08T05:20:44.000Z","profile_code":"prf_mine",
          "payload":{"body":"AED 1","client_msg_id":"6F1C2A8E-8A0B-4F7E-9D61-2C1F6A3B9E10",
                     "received_at":"2026-10-08T05:12:44.000Z","sender":"FAB"}}]
        """
        try Data(legacy.utf8).write(to: url)
        let outbox = Outbox(fileURL: url, api: StubAPI())
        let entries = try await outbox.entries()
        #expect(entries.count == 1)
        #expect(!entries[0].isParked)
        #expect(await outbox.status().pending == 1)
    }

    @Test("two concurrent flushes in one process never send the same entry twice")
    func serialisedFlush() async throws {
        let api = StubAPI()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue((0..<5).map { payload($0) }, profileCode: mine)
        async let a = outbox.flush()
        async let b = outbox.flush()
        _ = await (a, b)
        #expect(api.sentMessageCount == 5)
    }

    @Test("status summary counts waiting and parked separately")
    func summaries() {
        #expect(OutboxStatus().summary == "Nothing waiting")
        #expect(OutboxStatus(pending: 3).summary == "3 messages waiting")
        #expect(OutboxStatus(parked: 1).summary == "1 message not sent")
        #expect(OutboxStatus(pending: 1, parked: 2).summary == "1 waiting · 2 not sent")
    }
}
