import Foundation

/// The offline queue for SMS and card payments (`OutboxItem`), a JSON file in
/// the App Group so the App Intents (their own process) and the app share it. Every operation re-reads the file
/// under an `NSFileCoordinator`, so an entry another process added in between
/// is never overwritten. Delivery is at-least-once; `client_msg_id` makes the
/// server side exactly-once.
///
/// Failures are classified (`LedgerAPIError.kind`):
/// * unreachable (no data, airplane mode, DNS, timeout): the phone, not the
///   message, so it is not counted as an attempt and the flush stops; the
///   entry waits until a connection is back (`OutboxSync`), however long that
///   takes, and is parked only after `maxAge`;
/// * other transient (5xx, a busy database): retried with backoff, at most
///   `maxAttempts` times, then parked;
/// * permanent (42501 permission, 22023 validation, 4xx): a batch is split in
///   halves until the bad message is alone, which is parked — the others go
///   through. A permission error parks the profile's whole batch (it is about
///   the ledger, not a message);
/// * signed out: kept, not counted as an attempt, and the flush stops.
/// A per-message failure status in an otherwise successful response parks
/// only that message. Each flush sends per profile and kind, since SMS and
/// payments go to different RPCs (`Outbox+Flush.swift`).
public actor Outbox {
    /// `ingest_sms` and `ingest_wallet_transactions` take at most 200 items per call.
    public static let batchLimit = 200
    /// Automatic attempts before an entry is parked for the user.
    public static let maxAttempts = 8
    /// A message still unsent this long after it was captured is parked for
    /// the user, whatever the reason (a week without data is not normal).
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    let fileURL: URL
    let api: any SMSIngestAPI
    let backoff: Backoff
    let now: @Sendable () -> Date
    /// One flush at a time in this process: a second caller's flush runs after
    /// the current one (so its newly queued message is included, and no entry
    /// is sent twice by overlapping flushes).
    private var inFlight: Task<FlushReport, Never>?

    public init(fileURL: URL, api: any SMSIngestAPI, backoff: Backoff = Backoff(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.api = api
        self.backoff = backoff
        self.now = now
    }

    public static func defaultURL(container: URL) -> URL {
        container.appendingPathComponent("sms-outbox.json")
    }

    public func enqueue(_ payload: SMSPayload, profileCode: String) throws {
        try enqueue(items: [.sms(payload)], profileCode: profileCode)
    }

    /// One coordinated write for many messages. Already-queued ids are skipped.
    public func enqueue(_ payloads: [SMSPayload], profileCode: String) throws {
        try enqueue(items: payloads.map(OutboxItem.sms), profileCode: profileCode)
    }

    public func enqueue(_ payment: WalletPayment, profileCode: String) throws {
        try enqueue(items: [.wallet(payment)], profileCode: profileCode)
    }

    /// One coordinated write for many items of any kind. Already-queued ids are skipped.
    public func enqueue(items: [OutboxItem], profileCode: String) throws {
        let at = now()
        try mutate { entries in
            var known = Set(entries.map(\.id))
            for item in items where !known.contains(item.clientMsgId) {
                known.insert(item.clientMsgId)
                entries.append(OutboxEntry(item: item, profileCode: profileCode, enqueuedAt: at, nextAttemptAt: at))
            }
        }
    }

    public func entries() throws -> [OutboxEntry] { try OutboxFile.read(fileURL) }

    /// Entries that stopped retrying, newest first.
    public func parkedEntries() -> [OutboxEntry] {
        ((try? OutboxFile.read(fileURL)) ?? []).filter(\.isParked)
            .sorted { ($0.parkedAt ?? .distantPast) > ($1.parkedAt ?? .distantPast) }
    }

    public func status() -> OutboxStatus {
        let all = (try? OutboxFile.read(fileURL)) ?? []
        let pending = all.filter { !$0.isParked }
        return OutboxStatus(
            pending: pending.count,
            parked: all.count - pending.count,
            oldest: pending.map(\.enqueuedAt).min(),
            nextAttemptAt: pending.map(\.nextAttemptAt).min(),
            lastError: pending.compactMap(\.lastError).last)
    }

    public func removeAll() throws { try mutate { $0.removeAll() } }

    public func remove(_ ids: Set<UUID>) throws { try mutate { $0.removeAll { ids.contains($0.id) } } }

    /// Puts parked entries back in the queue with a fresh attempt budget,
    /// optionally pointed at another ledger (the current "SMS go to" choice,
    /// for messages parked because they went to a ledger the user can't post to).
    public func retry(_ ids: Set<UUID>, reassignTo profileCode: String? = nil) throws {
        let at = now()
        try mutate { entries in
            for i in entries.indices where ids.contains(entries[i].id) {
                entries[i].parkedAt = nil
                entries[i].parkedReason = nil
                entries[i].attempts = 0
                entries[i].lastError = nil
                entries[i].nextAttemptAt = at
                if let profileCode { entries[i].profileCode = profileCode }
            }
        }
    }

    /// Sends every due entry (all of them when `force`), oldest first, per
    /// profile and kind in batches. Parked entries are never sent here.
    @discardableResult
    public func flush(force: Bool = false) async -> FlushReport {
        // Chain after the previous flush instead of overlapping it.
        let previous = inFlight
        let task = Task { [previous] in
            _ = await previous?.value
            return await self.runFlush(force: force)
        }
        inFlight = task
        return await task.value
    }

    func mutate(_ change: (inout [OutboxEntry]) -> Void) throws {
        try OutboxFile.mutate(fileURL, change)
    }
}
