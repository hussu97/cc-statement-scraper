import Foundation
import Testing
@testable import LedgerKit

/// IOS-12r audit: an SMS or card payment saved without a ledger goes only to
/// the account it was captured under, never to whoever signs in next.
@Suite("Outbox — items saved without a ledger belong to the account that captured them")
struct OutboxOwnershipTests {
    let card = "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE"

    /// The App Group stores the app, the intents and the outbox share.
    final class Phone: @unchecked Sendable {
        let users: DeviceUserStore
        let targets: SMSTargetStore
        init() throws {
            let defaults = try #require(UserDefaults(suiteName: "ledger-owner-\(UUID().uuidString)"))
            users = DeviceUserStore(defaults: defaults)
            targets = SMSTargetStore(defaults: defaults)
        }
        func outbox(_ url: URL, _ api: StubAPI) -> Outbox {
            let (targets, users) = (targets, users)
            return Outbox(fileURL: url, api: api, pendingTarget: { targets.target?.profileCode },
                          deviceUser: { users.userID })
        }
        func intake(_ outbox: Outbox) -> SMSIntake {
            let targets = targets
            return SMSIntake(outbox: outbox, target: { targets.target })
        }
    }

    @Test("A signs out, an SMS arrives, B signs in: B's ledger never gets it; it waits for A, deletable")
    func otherAccountKeepsOut() async throws {
        let phone = try Phone()
        let api = StubAPI(.succeed(status: "created"))
        let url = temporaryOutboxURL()
        let outbox = phone.outbox(url, api)

        // A was signed in, then signed out: the target is cleared, A stays the last user.
        phone.users.userID = "user_a"
        phone.targets.target = nil
        let (outcome, _) = await phone.intake(outbox).handle(body: card, sender: "FAB")
        #expect(outcome == .queued(.noLedger))
        #expect(try await outbox.entries().first?.capturedBy == "user_a")

        // B signs in on the same phone.
        phone.users.userID = "user_b"
        phone.targets.target = SMSTarget(profileCode: "prf_b", name: "B's")
        await outbox.flush(force: true)
        #expect(api.calls.isEmpty)
        let parked = try #require(await outbox.parkedEntries().first)
        #expect(parked.isOtherAccounts && parked.parkedReason == Outbox.otherAccountReason)
        let row = ParkedMessage(parked, currentUser: outbox.currentUser)
        #expect(!row.canRetry && row.reason.contains("another account"))
        // Retry can't send it to B's ledger either.
        try await outbox.retry([parked.id], reassignTo: "prf_b")
        await outbox.flush(force: true)
        let stillWaiting = try await outbox.entries().first
        #expect(api.calls.isEmpty && stillWaiting?.profileCode == nil)

        // A signs back in: it is A's again, and goes to A's ledger.
        phone.users.userID = "user_a"
        phone.targets.target = SMSTarget(profileCode: "prf_a", name: "A's")
        await outbox.flush(force: true)
        #expect(api.calls.map(\.profile) == ["prf_a"])
        #expect(await outbox.status().isEmpty)
    }

    @Test("B can delete A's waiting item from Not sent")
    func otherAccountDeletable() async throws {
        let phone = try Phone()
        let outbox = phone.outbox(temporaryOutboxURL(), StubAPI())
        phone.users.userID = "user_a"
        _ = await phone.intake(outbox).handle(body: card, sender: "FAB")
        phone.users.userID = "user_b"
        phone.targets.target = SMSTarget(profileCode: "prf_b", name: "B's")
        await outbox.flush()
        let parked = try #require(await outbox.parkedEntries().first)
        try await outbox.remove([parked.id])
        #expect(await outbox.status().isEmpty)
    }

    @Test("the same account signing back in adopts its own items; a phone nobody signed in on adopts them too")
    func ownAndUnstamped() async throws {
        let phone = try Phone()
        let api = StubAPI(.succeed(status: "created"))
        let outbox = phone.outbox(temporaryOutboxURL(), api)
        _ = await phone.intake(outbox).handle(body: card, sender: "FAB")   // nobody ever signed in
        #expect(try await outbox.entries().first?.capturedBy == nil)
        phone.users.userID = "user_a"
        phone.targets.target = SMSTarget(profileCode: "prf_a", name: "A's")
        await outbox.flush()
        #expect(api.calls.map(\.profile) == ["prf_a"])
    }

    @Test("an item A filed in A's ledger can't be retried into B's ledger")
    func noRetryAcrossAccounts() async throws {
        let phone = try Phone()
        let api = StubAPI(.fail(.server(status: nil, code: "42501", message: "not a member")))
        let outbox = phone.outbox(temporaryOutboxURL(), api)
        phone.users.userID = "user_a"
        try await outbox.enqueue(SMSPayload(receivedAt: Date(), sender: "FAB", body: card), profileCode: "prf_a")
        phone.users.userID = "user_b"
        await outbox.flush()
        let parked = try #require(await outbox.parkedEntries().first)
        #expect(!ParkedMessage(parked, currentUser: "user_b").canRetry)
        #expect(ParkedMessage(parked, currentUser: "user_a").canRetry)
        try await outbox.retry([parked.id], reassignTo: "prf_b")
        #expect(try await outbox.entries().first?.profileCode == "prf_a")
    }

    @MainActor
    @Test("signing out, however it happens, clears \"SMS go to\" in the shared store")
    func targetCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "ledger-owner-\(UUID().uuidString)"))
        let store = SMSTargetStore(defaults: defaults)
        store.target = SMSTarget(profileCode: "prf_a", name: "A's")
        let profiles = ProfileStore(api: StubAPI(), selection: ProfileSelection(defaults: defaults), smsTargets: store)
        #expect(profiles.smsTarget != nil)
        profiles.clearSMSTarget()
        #expect(profiles.smsTarget == nil && store.target == nil)
    }
}
