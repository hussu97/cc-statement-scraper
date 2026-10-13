import Foundation

/// A flush sends per profile and kind: SMS to `ingest_sms`, card payments to
/// `ingest_wallet_transactions`. Both answer the same per-item result shape,
/// so settling, backoff and parking are shared.
struct BatchKey: Hashable, Comparable {
    let profileCode: String
    let kind: OutboxItem.Kind

    static func < (a: BatchKey, b: BatchKey) -> Bool { (a.profileCode, a.kind) < (b.profileCode, b.kind) }
}

extension Outbox {
    /// One RPC call for a batch of a single kind.
    private func send(_ batch: [OutboxEntry], kind: OutboxItem.Kind, profileCode: String) async throws -> [SMSIngestResult] {
        switch kind {
        case .sms: try await api.ingestSMS(profileCode: profileCode, messages: batch.compactMap(\.sms))
        case .wallet: try await api.ingestWalletPayments(profileCode: profileCode, items: batch.compactMap(\.wallet))
        }
    }

    func runFlush(force: Bool) async -> FlushReport {
        var report = FlushReport()
        var all = (try? OutboxFile.read(fileURL)) ?? []
        // Items saved before a ledger was known go to the "SMS go to" ledger now (IOS-12r).
        // Only the account they were captured under gets them (IOS-12r audit).
        if all.contains(where: { $0.profileCode == nil }), let target = pendingTarget(),
           (try? adoptPending(profileCode: target, userID: deviceUser())) != nil {
            all = (try? OutboxFile.read(fileURL)) ?? []
        }
        var groups: [BatchKey: [OutboxEntry]] = [:]
        for entry in all.sorted(by: { $0.enqueuedAt < $1.enqueuedAt })
        where !entry.isParked && (force || entry.nextAttemptAt <= now()) {
            guard let code = entry.profileCode else { continue }   // no ledger yet: waits
            groups[BatchKey(profileCode: code, kind: entry.kind), default: []].append(entry)
        }

        outer: for key in groups.keys.sorted() {
            let profileCode = key.profileCode
            let entries = groups[key]!
            var queue: [[OutboxEntry]] = stride(from: 0, to: entries.count, by: Self.batchLimit).map {
                Array(entries[$0..<min($0 + Self.batchLimit, entries.count)])
            }
            while !queue.isEmpty {
                let batch = queue.removeFirst()
                do {
                    let results = try await send(batch, kind: key.kind, profileCode: profileCode)
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
                            // group's due entries without hammering the server.
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
    func settle(_ batch: [OutboxEntry], results: [SMSIngestResult], report: inout FlushReport) {
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

    func recordFailure(_ batch: [OutboxEntry], error: LedgerAPIError, countsAsAttempt: Bool,
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

    func park(_ batch: [OutboxEntry], reason: String, report: inout FlushReport) {
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
        if error.isPermission { return "You can't add to this ledger: only its owners can." }
        return "Ledger rejected this message: \(error.description)"
    }
}
