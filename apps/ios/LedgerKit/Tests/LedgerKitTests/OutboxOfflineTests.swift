import Foundation
import Testing
@testable import LedgerKit

@Suite("Outbox — no data for a long time loses nothing and sends when the connection is back")
struct OutboxOfflineTests {
    let mine = "prf_mine"
    let other = "prf_other"
    let offline = LedgerAPIError.network(String(URLError.Code.notConnectedToInternet.rawValue))

    func payload(_ n: Int) -> SMSPayload {
        SMSPayload(receivedAt: Date(timeIntervalSince1970: 1_791_436_364 + Double(n)), sender: "FAB",
                   body: "Purchase of AED \(n).00 with Credit Card ending 1234")
    }

    @Test("unreachable: URLError connectivity codes only")
    func unreachableClassification() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .dataNotAllowed, .cannotFindHost,
                                    .networkConnectionLost, .internationalRoamingOff] {
            #expect(LedgerAPIError.network(String(code.rawValue)).isUnreachable)
        }
        #expect(!LedgerAPIError.network(String(URLError.Code.badServerResponse.rawValue)).isUnreachable)
        #expect(!LedgerAPIError.network("DecodingError").isUnreachable)
        #expect(!LedgerAPIError.server(status: 503, code: nil, message: "x").isUnreachable)
        #expect(!LedgerAPIError.notSignedIn.isUnreachable)
    }

    @Test("offline does not use up attempts: dozens of tries later the message is still waiting")
    func offlineNotCounted() async throws {
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(.fail(offline)), now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: mine)
        for _ in 0..<(Outbox.maxAttempts * 4) {
            clock.advance(600)
            await outbox.flush(force: true)
        }
        let entry = try #require(try await outbox.entries().first)
        #expect(entry.attempts == 0)
        #expect(!entry.isParked)
        #expect(entry.sms?.receivedAt == payload(1).receivedAt)
    }

    @Test("offline stops the flush: other profiles are not tried")
    func offlineStopsFlush() async throws {
        let api = StubAPI(.fail(offline))
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        try await outbox.enqueue(payload(1), profileCode: mine)
        try await outbox.enqueue(payload(2), profileCode: other)
        let report = await outbox.flush()
        #expect(api.calls.count == 1)
        #expect(report.error == offline)
        #expect(report.remaining == 2)
        #expect(SMSIntake.queueReason(report.error) == .offline)
    }

    @Test("a message unsent for 7 days is parked for the user, not dropped")
    func parkedAfterMaxAge() async throws {
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(.fail(offline)), now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: mine)
        clock.advance(Outbox.maxAge - 60)
        await outbox.flush(force: true)
        #expect(await outbox.status().pending == 1)
        clock.advance(120)
        let report = await outbox.flush(force: true)
        #expect(report.parked.count == 1)
        let parked = try #require(await outbox.parkedEntries().first)
        #expect(parked.parkedReason?.hasPrefix("Not sent for 7 days") == true)
    }

    @Test("signed out is never parked by age: signing in sends it")
    func signedOutNotAged() async throws {
        let clock = TestClock()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: StubAPI(.fail(.notSignedIn)), now: { clock.now })
        try await outbox.enqueue(payload(1), profileCode: mine)
        clock.advance(Outbox.maxAge * 2)
        await outbox.flush(force: true)
        #expect(await outbox.status().pending == 1)
    }

    @Test("background plan: nothing waiting → none; waiting → no earlier than the next attempt")
    func plan() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(OutboxSync.plan(OutboxStatus(), now: now) == nil)
        #expect(OutboxSync.plan(OutboxStatus(parked: 3), now: now) == nil)
        #expect(OutboxSync.plan(OutboxStatus(pending: 1, nextAttemptAt: now.addingTimeInterval(30)), now: now)
                == .init(earliestBegin: now.addingTimeInterval(30)))
        #expect(OutboxSync.plan(OutboxStatus(pending: 1, nextAttemptAt: now.addingTimeInterval(-300)), now: now)
                == .init(earliestBegin: now))
    }

    @Test("connection back: sends everything waiting at once, ignoring backoff")
    func pathBackFlushes() async throws {
        let clock = TestClock()
        let api = StubAPI(.fail(offline))
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api, now: { clock.now })
        let sync = OutboxSync(outbox: outbox)
        try await outbox.enqueue([payload(1), payload(2)], profileCode: mine)

        #expect(await sync.pathChanged(satisfied: false) == nil)   // baseline
        await outbox.flush()                                        // fails, backs off
        #expect(await sync.currentPlan(now: clock.now) != nil)
        #expect(await sync.pathChanged(satisfied: false) == nil)

        api.behaviour = .succeed(status: "new")
        let report = try #require(await sync.pathChanged(satisfied: true))
        #expect(report.sent == 2)
        #expect(await outbox.status().pending == 0)
        #expect(await sync.currentPlan(now: clock.now) == nil)
    }

    @Test("connection report: the first one and a still-online one do nothing")
    func pathNoOps() async throws {
        let api = StubAPI()
        let outbox = Outbox(fileURL: temporaryOutboxURL(), api: api)
        let sync = OutboxSync(outbox: outbox)
        try await outbox.enqueue(payload(1), profileCode: mine)
        #expect(await sync.pathChanged(satisfied: true) == nil)
        #expect(await sync.pathChanged(satisfied: true) == nil)
        #expect(api.calls.isEmpty)
        // Back online with nothing waiting: no request.
        try await outbox.removeAll()
        await sync.pathChanged(satisfied: false)
        #expect(await sync.pathChanged(satisfied: true) == nil)
        #expect(api.calls.isEmpty)
    }

    @Test("background task IDs are derived from the bundle id, never hard-coded")
    func taskIDsFollowBundleID() {
        let ids = OutboxSync.TaskIDs(bundleIdentifier: "com.example.ledger")
        #expect(ids.refresh == "com.example.ledger.outbox-refresh")
        #expect(ids.processing == "com.example.ledger.outbox-send")
        #expect(ids.all == [ids.refresh, ids.processing])
        // The convenience reads this process's bundle and keeps the same suffixes.
        #expect(OutboxSync.refreshTaskID.hasSuffix(".outbox-refresh"))
        #expect(OutboxSync.processingTaskID.hasSuffix(".outbox-send"))
    }

    @Test("background task IDs and modes are declared in the app's Info.plist")
    func infoPlistDeclaresTasks() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Ledger/Info.plist")
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        // The app's bundle id is $(LEDGER_BUNDLE_PREFIX) (project.yml), so the IDs
        // derived from it at run time are the ones the Info.plist expands to.
        let ids = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        #expect(Set(ids) == Set(OutboxSync.TaskIDs(bundleIdentifier: "$(LEDGER_BUNDLE_PREFIX)").all))
        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("fetch") && modes.contains("processing"))
    }
}
