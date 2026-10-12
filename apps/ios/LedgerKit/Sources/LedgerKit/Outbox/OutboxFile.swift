import Foundation

public struct OutboxStatus: Sendable, Equatable {
    /// Still being retried automatically.
    public let pending: Int
    /// Stopped; needs the user (Settings → Retry / Delete).
    public let parked: Int
    public let oldest: Date?
    public let nextAttemptAt: Date?
    public let lastError: String?
    /// Saved while no ledger was known (signed out, no owned ledger): sent once
    /// the "SMS go to" ledger is known (BACKLOG IOS-12r).
    public let awaitingLedger: Int
    /// Entries of any kind captured more than `Outbox.staleAfter` ago: the
    /// queue is stuck, so the Settings tab badge and the Overview strip say so.
    public let stale: Int
    /// How many of `stale` are card payments ("Log Card Payment"); the rest are SMS.
    public let stalePayments: Int

    public init(pending: Int = 0, parked: Int = 0, oldest: Date? = nil, nextAttemptAt: Date? = nil,
                lastError: String? = nil, awaitingLedger: Int = 0, stale: Int = 0, stalePayments: Int = 0) {
        self.pending = pending
        self.parked = parked
        self.oldest = oldest
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.awaitingLedger = awaitingLedger
        self.stale = stale
        self.stalePayments = stalePayments
    }

    /// Not sent yet and not given up on: retrying, or waiting for a ledger.
    public var waiting: Int { pending + awaitingLedger }

    public var isEmpty: Bool { waiting == 0 && parked == 0 }

    /// `"Nothing waiting"`, `"3 messages waiting"`, `"1 waiting · 2 not sent"`.
    public var summary: String {
        let waitingText = waiting == 1 ? "1 message waiting" : "\(waiting) messages waiting"
        switch (waiting, parked) {
        case (0, 0): return "Nothing waiting"
        case (_, 0): return waitingText
        case (0, _): return parked == 1 ? "1 message not sent" : "\(parked) messages not sent"
        default: return "\(waiting) waiting · \(parked) not sent"
        }
    }

    /// Settings' line for messages and payments saved without a ledger, nil when none.
    public var awaitingLedgerNote: String? {
        guard awaitingLedger > 0 else { return nil }
        return awaitingLedger == 1
            ? "1 item arrived while no ledger was set for SMS. It goes to the “SMS go to” ledger once one is set."
            : "\(awaitingLedger) items arrived while no ledger was set for SMS. They go to the “SMS go to” ledger once one is set."
    }

    /// The Settings tab badge: how many items are stuck (0 shows none).
    public var badgeCount: Int { stale }

    /// The Overview strip, nil when nothing is stuck.
    /// `"2 SMS and 1 card payment haven't reached Bank Ledger"`.
    public var staleAlert: StaleOutboxAlert? {
        guard stale > 0 else { return nil }
        let one = stale == 1
        let what = DeviceQueue.phrase(sms: stale - stalePayments, payments: stalePayments, pdfs: 0)
        let title = "\(what) \(one ? "hasn't" : "haven't") reached Bank Ledger"
        let detail: String =
            if awaitingLedger > 0 {
                "No ledger was set for SMS when \(one ? "it" : "they") arrived. Open Settings → SMS."
            } else if parked > 0 {
                "Stopped retrying. Open Settings to retry or delete \(one ? "it" : "them")."
            } else {
                "Waiting for over an hour. Open Settings to send \(one ? "it" : "them") now."
            }
        return StaleOutboxAlert(title: title, detail: detail)
    }
}

/// The Overview strip for a stuck outbox.
public struct StaleOutboxAlert: Sendable, Equatable {
    public let title: String
    public let detail: String
}

/// What signing out deletes from this phone, after the person confirms
/// (BACKLOG IOS-12r): left behind, SMS bodies and card payments would be sent
/// under whoever signs in next.
public struct DeviceQueue: Sendable, Equatable {
    /// SMS in the outbox: waiting, waiting for a ledger, or not sent.
    public let messages: Int
    /// Card payments ("Log Card Payment") in the outbox, likewise.
    public let payments: Int
    /// PDFs the share extension saved for later, and ones the server refused.
    public let pdfs: Int

    public init(messages: Int, payments: Int = 0, pdfs: Int) {
        self.messages = messages
        self.payments = payments
        self.pdfs = pdfs
    }

    public var isEmpty: Bool { messages + payments + pdfs == 0 }

    /// The sign-out confirmation, naming the counts; nil when nothing would be lost.
    /// `"2 SMS, 1 card payment and 1 PDF haven't reached Bank Ledger. Signing out deletes them from this phone."`
    public var signOutWarning: String? {
        guard !isEmpty else { return nil }
        let one = messages + payments + pdfs == 1
        return "\(Self.phrase(sms: messages, payments: payments, pdfs: pdfs)) \(one ? "hasn't" : "haven't") reached Bank Ledger. "
            + "Signing out deletes \(one ? "it" : "them") from this phone."
    }

    /// `"2 SMS"`, `"1 card payment"`, `"2 SMS, 1 card payment and 3 PDFs"`.
    static func phrase(sms: Int, payments: Int, pdfs: Int) -> String {
        var parts: [String] = []
        if sms > 0 { parts.append("\(sms) SMS") }
        if payments > 0 { parts.append(payments == 1 ? "1 card payment" : "\(payments) card payments") }
        if pdfs > 0 { parts.append(pdfs == 1 ? "1 PDF" : "\(pdfs) PDFs") }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
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
