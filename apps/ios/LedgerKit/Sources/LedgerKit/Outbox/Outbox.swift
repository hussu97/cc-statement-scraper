import Foundation

/// A message waiting to reach `ingest_sms`.
public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { payload.clientMsgId }
    public let payload: SMSPayload
    /// The ledger it goes to. Reassigned only when the user retries a parked entry.
    public var profileCode: String
    public let enqueuedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    /// Set when the entry stopped being retried automatically: a permanent
    /// error (no permission, invalid message), a failing per-message status, or
    /// too many attempts. It then waits in Settings for Retry or Delete and
    /// never blocks the rest of the queue. Absent in files written before
    /// parking existed, which decode as not parked.
    public var parkedAt: Date?
    public var parkedReason: String?

    public var isParked: Bool { parkedAt != nil }
}

/// The offline queue for SMS, a JSON file in the App Group so the App Intent
/// (its own process) and the app share it. Every operation re-reads the file
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
/// only that message.
public actor Outbox {
    /// `ingest_sms` takes at most 200 messages per call.
    public static let batchLimit = 200
    /// Automatic attempts before an entry is parked for the user.
    public static let maxAttempts = 8
    /// A message still unsent this long after it was captured is parked for
    /// the user, whatever the reason (a week without data is not normal).
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    private let fileURL: URL
    private let api: any SMSIngestAPI
    private let backoff: Backoff
    private let now: @Sendable () -> Date
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
        try enqueue([payload], profileCode: profileCode)
    }

    /// One coordinated write for many messages. Already-queued ids are skipped.
    public func enqueue(_ payloads: [SMSPayload], profileCode: String) throws {
        let at = now()
        try mutate { entries in
            var known = Set(entries.map(\.id))
            for payload in payloads where !known.contains(payload.clientMsgId) {
                known.insert(payload.clientMsgId)
                entries.append(OutboxEntry(payload: payload, profileCode: profileCode, enqueuedAt: at,
                                           attempts: 0, nextAttemptAt: at, lastError: nil))
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
    /// profile in batches. Parked entries are never sent here.
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

    private func runFlush(force: Bool) async -> FlushReport {
        var report = FlushReport()
        let all = (try? OutboxFile.read(fileURL)) ?? []
        let due = all.filter { !$0.isParked && (force || $0.nextAttemptAt <= now()) }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
        let byProfile = Dictionary(grouping: due, by: \.profileCode)

        outer: for profileCode in byProfile.keys.sorted() {
            let entries = byProfile[profileCode]!
            var queue: [[OutboxEntry]] = stride(from: 0, to: entries.count, by: Self.batchLimit).map {
                Array(entries[$0..<min($0 + Self.batchLimit, entries.count)])
            }
            while !queue.isEmpty {
                let batch = queue.removeFirst()
                do {
                    let results = try await api.ingestSMS(profileCode: profileCode, messages: batch.map(\.payload))
                    settle(batch, results: results, report: &report)
                } catch {
                    let apiError = (error as? LedgerAPIError) ?? .network(String(describing: type(of: error)))
                    report.error = apiError
                    switch apiError.kind {
                    case .signedOut:
                        report.failed += batch.count
                        recordFailure(batch, error: apiError, countsAsAttempt: false, report: &report)
                        break outer
                    case .transient where apiError.isUnreachable:
                        // No connection: every other profile would fail too.
                        report.failed += batch.count
                        recordFailure(batch, error: apiError, countsAsAttempt: false, report: &report)
                        break outer
                    case .transient:
                        // The rest of this profile would most likely fail the same
                        // way right now; leave it for the next flush.
                        report.failed += batch.count
                        recordFailure(batch, error: apiError, countsAsAttempt: true, report: &report)
                        continue outer
                    case .permanent:
                        if apiError.isPermission {
                            // About the ledger, not a message: park the whole
                            // profile's due entries without hammering the server.
                            let rest = [batch] + queue
                            for chunk in rest {
                                report.failed += chunk.count
                                park(chunk, reason: Self.reason(for: apiError), report: &report)
                            }
                            continue outer
                        }
                        if batch.count > 1 {
                            // Isolate the bad message(s); the others go through.
                            let mid = batch.count / 2
                            queue.insert(contentsOf: [Array(batch[..<mid]), Array(batch[mid...])], at: 0)
                        } else {
                            report.failed += 1
                            park(batch, reason: Self.reason(for: apiError), report: &report)
                        }
                    }
                }
            }
        }
        report.remaining = ((try? OutboxFile.read(fileURL)) ?? []).filter { !$0.isParked }.count
        return report
    }

    /// A response arrived: drop delivered entries, park per-message failures,
    /// and count an attempt for any entry the server did not answer for.
    private func settle(_ batch: [OutboxEntry], results: [SMSIngestResult], report: inout FlushReport) {
        var byID: [String: SMSIngestResult] = [:]
        for r in results where byID[r.clientMsgId.lowercased()] == nil { byID[r.clientMsgId.lowercased()] = r }
        var delivered = Set<UUID>()
        var failedStatus: [UUID: String] = [:]
        var unanswered: [OutboxEntry] = []
        for entry in batch {
            guard let result = byID[entry.id.uuidString.lowercased()] else {
                unanswered.append(entry)
                continue
            }
            report.results.append(result)
            report.sent += 1
            if result.isFailure {
                failedStatus[entry.id] = result.failureReason
            } else {
                delivered.insert(entry.id)
            }
        }
        let at = now()
        try? mutate { entries in
            entries.removeAll { delivered.contains($0.id) }
            for i in entries.indices {
                if let reason = failedStatus[entries[i].id] {
                    entries[i].parkedAt = at
                    entries[i].parkedReason = reason
                    entries[i].lastError = reason
                }
            }
        }
        for (id, reason) in failedStatus { report.parked[id] = reason }
        if !unanswered.isEmpty {
            report.failed += unanswered.count
            recordFailure(unanswered, error: .server(status: nil, code: nil, message: "Ledger didn't confirm this message."),
                          countsAsAttempt: true, report: &report)
        }
    }

    private func recordFailure(_ batch: [OutboxEntry], error: LedgerAPIError, countsAsAttempt: Bool,
                               report: inout FlushReport) {
        let ids = Set(batch.map(\.id))
        let at = now()
        var parkedNow: [UUID: String] = [:]
        try? mutate { entries in
            for i in entries.indices where ids.contains(entries[i].id) {
                if countsAsAttempt { entries[i].attempts += 1 }
                entries[i].lastError = error.description
                let reason: String? =
                    if countsAsAttempt && entries[i].attempts >= Self.maxAttempts {
                        "Gave up after \(entries[i].attempts) tries: \(error.description)"
                    } else if error.kind != .signedOut && at.timeIntervalSince(entries[i].enqueuedAt) >= Self.maxAge {
                        "Not sent for 7 days: \(error.description)"
                    } else {
                        nil
                    }
                if let reason {
                    entries[i].parkedAt = at
                    entries[i].parkedReason = reason
                    parkedNow[entries[i].id] = reason
                } else {
                    entries[i].nextAttemptAt = at.addingTimeInterval(backoff.delay(afterAttempt: max(entries[i].attempts, 1)))
                }
            }
        }
        report.parked.merge(parkedNow) { $1 }
    }

    private func park(_ batch: [OutboxEntry], reason: String, report: inout FlushReport) {
        let ids = Set(batch.map(\.id))
        let at = now()
        try? mutate { entries in
            for i in entries.indices where ids.contains(entries[i].id) {
                entries[i].attempts += 1
                entries[i].parkedAt = at
                entries[i].parkedReason = reason
                entries[i].lastError = reason
            }
        }
        for id in ids { report.parked[id] = reason }
    }

    static func reason(for error: LedgerAPIError) -> String {
        if error.isPermission { return "You can't add SMS to this ledger: only its owners can." }
        return "Ledger rejected this message: \(error.description)"
    }

    private func mutate(_ change: (inout [OutboxEntry]) -> Void) throws {
        try OutboxFile.mutate(fileURL, change)
    }
}
