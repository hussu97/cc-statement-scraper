import Foundation

/// A message waiting to reach `ingest_sms`.
public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { payload.clientMsgId }
    public let payload: SMSPayload
    public let profileCode: String
    public let enqueuedAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
}

public struct OutboxStatus: Sendable, Equatable {
    public let pending: Int
    public let oldest: Date?
    public let nextAttemptAt: Date?
    public let lastError: String?

    public var isEmpty: Bool { pending == 0 }

    /// `"Nothing waiting"`, `"3 messages waiting"`.
    public var summary: String {
        switch pending {
        case 0: "Nothing waiting"
        case 1: "1 message waiting"
        default: "\(pending) messages waiting"
        }
    }
}

public struct FlushReport: Sendable, Equatable {
    public var sent = 0
    public var results: [SMSIngestResult] = []
    public var failed = 0
    public var error: LedgerAPIError?
    public var remaining = 0
}

/// Exponential backoff: 30 s, 60 s, 2 min … capped at an hour.
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval = 30
    public var cap: TimeInterval = 3600

    public init(base: TimeInterval = 30, cap: TimeInterval = 3600) {
        self.base = base
        self.cap = cap
    }

    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 20)))
        return min(cap, base * pow(2, exponent))
    }
}

/// The offline queue for SMS, a JSON file in the App Group so the App Intent
/// (its own process) and the app share it. Every operation re-reads the file
/// under an `NSFileCoordinator`, so an entry another process added in between
/// is never overwritten. Delivery is at-least-once; `client_msg_id` makes the
/// server side exactly-once, so two processes flushing at the same moment is
/// harmless.
public actor Outbox {
    /// `ingest_sms` takes at most 200 messages per call.
    public static let batchLimit = 200

    private let fileURL: URL
    private let api: any SMSIngestAPI
    private let backoff: Backoff
    private let now: @Sendable () -> Date

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

    public func status() -> OutboxStatus {
        let entries = (try? OutboxFile.read(fileURL)) ?? []
        return OutboxStatus(
            pending: entries.count,
            oldest: entries.map(\.enqueuedAt).min(),
            nextAttemptAt: entries.map(\.nextAttemptAt).min(),
            lastError: entries.compactMap(\.lastError).last)
    }

    public func removeAll() throws { try mutate { $0.removeAll() } }

    /// Sends every due entry (all of them when `force`), oldest first, per
    /// profile in batches. Stops at the first non-transient error (signed out),
    /// since every later batch would fail the same way.
    @discardableResult
    public func flush(force: Bool = false) async -> FlushReport {
        var report = FlushReport()
        let all = (try? OutboxFile.read(fileURL)) ?? []
        let due = all.filter { force || $0.nextAttemptAt <= now() }.sorted { $0.enqueuedAt < $1.enqueuedAt }
        let byProfile = Dictionary(grouping: due, by: \.profileCode)

        outer: for profileCode in byProfile.keys.sorted() {
            let entries = byProfile[profileCode]!
            for start in stride(from: 0, to: entries.count, by: Self.batchLimit) {
                let batch = Array(entries[start..<min(start + Self.batchLimit, entries.count)])
                let ids = Set(batch.map(\.id))
                do {
                    let results = try await api.ingestSMS(profileCode: profileCode, messages: batch.map(\.payload))
                    report.sent += batch.count
                    report.results += results
                    try? mutate { $0.removeAll { ids.contains($0.id) } }
                } catch {
                    let apiError = (error as? LedgerAPIError) ?? .network(String(describing: type(of: error)))
                    report.failed += batch.count
                    report.error = apiError
                    let at = now()
                    try? mutate { entries in
                        for i in entries.indices where ids.contains(entries[i].id) {
                            entries[i].attempts += 1
                            entries[i].nextAttemptAt = at.addingTimeInterval(backoff.delay(afterAttempt: entries[i].attempts))
                            entries[i].lastError = apiError.description
                        }
                    }
                    if !apiError.isTransient { break outer }
                }
            }
        }
        report.remaining = ((try? OutboxFile.read(fileURL)) ?? []).count
        return report
    }

    private func mutate(_ change: (inout [OutboxEntry]) -> Void) throws {
        try OutboxFile.mutate(fileURL, change)
    }
}

/// Coordinated, atomic, file-protected reads and writes of the outbox file.
enum OutboxFile {
    static func read(_ url: URL) throws -> [OutboxEntry] {
        var result: Result<[OutboxEntry], any Error> = .success([])
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try decode(u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    static func mutate(_ url: URL, _ change: (inout [OutboxEntry]) -> Void) throws {
        var thrown: (any Error)?
        var coordError: NSError?
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            do {
                var entries = try decode(u)
                change(&entries)
                let data = try LedgerJSON.makeEncoder().encode(entries)
                // The file holds SMS bodies: readable after first unlock (a
                // Shortcuts automation runs on a locked phone), never synced.
                try data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = u
                try? mutable.setResourceValues(values)
            } catch {
                thrown = error
            }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }

    private static func decode(_ url: URL) throws -> [OutboxEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        return try LedgerJSON.decode([OutboxEntry].self, from: data)
    }
}
