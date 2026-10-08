import Foundation

public struct OutboxStatus: Sendable, Equatable {
    /// Still being retried automatically.
    public let pending: Int
    /// Stopped; needs the user (Settings → Retry / Delete).
    public let parked: Int
    public let oldest: Date?
    public let nextAttemptAt: Date?
    public let lastError: String?

    public init(pending: Int = 0, parked: Int = 0, oldest: Date? = nil, nextAttemptAt: Date? = nil, lastError: String? = nil) {
        self.pending = pending
        self.parked = parked
        self.oldest = oldest
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }

    public var isEmpty: Bool { pending == 0 && parked == 0 }

    /// `"Nothing waiting"`, `"3 messages waiting"`, `"1 waiting · 2 not sent"`.
    public var summary: String {
        let waiting = pending == 1 ? "1 message waiting" : "\(pending) messages waiting"
        switch (pending, parked) {
        case (0, 0): return "Nothing waiting"
        case (_, 0): return waiting
        case (0, _): return parked == 1 ? "1 message not sent" : "\(parked) messages not sent"
        default: return "\(pending) waiting · \(parked) not sent"
        }
    }
}

public struct FlushReport: Sendable, Equatable {
    /// Messages the server accepted a result for (including parked per-message failures).
    public var sent = 0
    public var results: [SMSIngestResult] = []
    /// Messages whose request failed and that stay queued (or were parked).
    public var failed = 0
    /// Messages parked during this flush, with the reason shown to the user.
    public var parked: [UUID: String] = [:]
    /// The last request error, if any.
    public var error: LedgerAPIError?
    /// Entries still queued for automatic retry after this flush.
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
