import Foundation

/// What happened to one message handed to "Log Bank SMS".
public enum SMSIntakeOutcome: Equatable, Sendable {
    /// Why a message is still waiting on the phone.
    public enum QueueReason: String, Sendable, Equatable {
        case offline, signedOut, serverUnavailable, pending
    }

    case dropped(SMSCapture.Decision)
    /// No ledger is set for SMS (signed out, or the user owns none).
    case noProfile
    /// Reached the server; `status` is `ingest_sms`'s per-message status.
    case delivered(status: String)
    /// Saved in the outbox; it will be retried automatically.
    case queued(QueueReason)
    /// Will not be retried automatically (no permission, refused by the
    /// server); it waits in Settings for Retry or Delete.
    case parked(reason: String)
    case failed(String)

    /// The short line Shortcuts shows. Never echoes the message. `ledger` is the
    /// "SMS go to" ledger's name.
    public func dialog(ledger: String? = nil) -> String {
        let to = ledger.map { "to \($0)" } ?? "to Ledger"
        switch self {
        case .dropped(let decision): return decision.userMessage
        case .noProfile:
            return "Not logged: Ledger has no ledger set for SMS. Open Ledger → Settings and sign in or choose “SMS go to”."
        case .delivered(let status): return Self.statusMessage(status, to: to)
        case .queued(let reason):
            switch reason {
            case .offline: return "Saved on this iPhone. It will be sent \(to) when you're back online."
            case .signedOut: return "Saved on this iPhone, but you're signed out. Open Ledger and sign in to send it."
            case .serverUnavailable: return "Saved on this iPhone. Ledger didn't respond; it will retry automatically."
            case .pending: return "Saved on this iPhone. It will be sent \(to) shortly."
            }
        case .parked(let reason):
            return "Not logged. \(reason) Open Ledger → Settings → SMS to retry or delete it."
        case .failed: return "Couldn't save the message on this iPhone."
        }
    }

    /// Breadcrumb outcome: an opaque word, safe to send to Sentry.
    public var telemetryOutcome: String {
        switch self {
        case .dropped(let d):
            switch d {
            case .accept: "accepted"
            case .dropOTP: "dropped_otp"
            case .dropNotCreditCard(let reason): "dropped_\(reason)"
            case .dropEmpty: "dropped_empty"
            }
        case .noProfile: "no_profile"
        case .delivered(let status): "delivered_\(status)"
        case .queued(let reason): "queued_\(reason.rawValue)"
        case .parked: "parked"
        case .failed: "failed"
        }
    }

    /// Outcomes the user should act on (shown in red in Settings).
    public var needsAttention: Bool {
        switch self {
        case .noProfile, .parked, .failed: true
        case .queued(let reason): reason == .signedOut
        case .delivered(let status): ["unknown_card", "held", "unparsed"].contains(status)
        case .dropped: false
        }
    }

    static func statusMessage(_ status: String, to: String) -> String {
        switch status {
        case "unknown_card":
            "Logged \(to), but Ledger doesn't know this card yet. Open Ledger → Overview → Needs review to add it."
        case "held":
            "Logged \(to). It needs a quick check: open Ledger → Overview → Needs review."
        case "unparsed": "Logged \(to), but Ledger can't read this message format yet."
        case "ignored": "Logged \(to) as not a card purchase."
        case "duplicate_delivery", "already_linked": "Already logged."
        case "rejected_otp": "Skipped: one-time passcode."
        default: "Logged \(to)."
        }
    }
}

/// The App Intent's whole decision path, kept here so `swift test` drives it
/// with a stub API: filter on the device → enqueue in the shared outbox →
/// try to deliver now. The message is persisted before any network call, so a
/// process killed mid-request loses nothing.
public struct SMSIntake: Sendable {
    let outbox: Outbox
    let target: @Sendable () -> SMSTarget?
    let log: CaptureLog?

    public init(outbox: Outbox, target: @escaping @Sendable () -> SMSTarget?, log: CaptureLog? = nil) {
        self.outbox = outbox
        self.target = target
        self.log = log
    }

    /// Handles one message and returns the outcome with the line to show.
    public func handle(body: String, sender: String?, receivedAt: Date = Date(),
                       clientMsgId: UUID = UUID(), isTest: Bool = false) async -> (outcome: SMSIntakeOutcome, dialog: String) {
        let destination = target()
        let outcome = await decide(body: body, sender: sender, receivedAt: receivedAt, clientMsgId: clientMsgId,
                                   target: destination)
        let dialog = outcome.dialog(ledger: destination?.name)
        log?.record(CaptureRecord(at: receivedAt, outcome: outcome.telemetryOutcome, message: dialog, isTest: isTest))
        return (outcome, dialog)
    }

    private func decide(body: String, sender: String?, receivedAt: Date, clientMsgId: UUID,
                        target: SMSTarget?) async -> SMSIntakeOutcome {
        let (decision, payload) = SMSCapture.payload(body: body, sender: sender, receivedAt: receivedAt,
                                                     clientMsgId: clientMsgId)
        guard let payload else { return .dropped(decision) }
        guard let target else { return .noProfile }
        do {
            try await outbox.enqueue(payload, profileCode: target.profileCode)
        } catch {
            return .failed(String(describing: type(of: error)))
        }
        let report = await outbox.flush()
        if let reason = report.parked[payload.clientMsgId] { return .parked(reason: reason) }
        let wanted = payload.clientMsgId.uuidString.lowercased()
        if let result = report.results.first(where: { $0.clientMsgId.lowercased() == wanted }) {
            return .delivered(status: result.status)
        }
        return .queued(Self.queueReason(report.error))
    }

    static func queueReason(_ error: LedgerAPIError?) -> SMSIntakeOutcome.QueueReason {
        guard let error else { return .pending }
        switch (error, error.kind) {
        case (.network, _): return .offline
        case (_, .signedOut): return .signedOut
        default: return .serverUnavailable
        }
    }

    /// The in-app "Send test": runs the same path with a synthetic message that
    /// is not a transaction (so it is dropped on the phone and nothing is
    /// stored), then sends anything waiting, to check the session and network.
    public func selfTest(now: Date = Date()) async -> SMSSelfTest {
        let destination = target()
        let outcome = await decide(body: SMSSelfTest.message, sender: "Ledger test", receivedAt: now,
                                   clientMsgId: UUID(), target: destination)
        let filterOK: Bool = if case .dropped(let decision) = outcome { !decision.isAccepted } else { false }
        let report = await outbox.flush(force: true)
        let result = SMSSelfTest(target: destination, filterOK: filterOK, flushError: report.error,
                                 parked: report.parked.count)
        log?.record(CaptureRecord(at: now, outcome: result.passed ? "test_ok" : "test_failed",
                                  message: result.message, isTest: true))
        return result
    }
}

/// The result of "Send test", in words.
public struct SMSSelfTest: Sendable, Equatable {
    /// Contains no amount and no card wording, so the filter drops it.
    public static let message = "Ledger test message. This is not a transaction."

    public let target: SMSTarget?
    public let filterOK: Bool
    public let flushError: LedgerAPIError?
    public let parked: Int

    public var passed: Bool { target != nil && filterOK && (flushError == nil || flushError?.kind == .transient) }

    public var message: String {
        guard let target else { return "Test failed: no ledger is set for SMS. Choose one under “SMS go to”." }
        guard filterOK else { return "Test failed: the on-device filter didn't run as expected." }
        if let flushError {
            switch flushError.kind {
            case .signedOut: return "Test failed: you're signed out, so SMS would wait on this iPhone."
            case .transient: return "Log Bank SMS works, but Ledger is unreachable right now. Messages will wait on this iPhone."
            case .permanent: return "Test failed: \(flushError.description)"
            }
        }
        if parked > 0 { return "Log Bank SMS works and files card alerts in \(target.name). Some waiting messages couldn't be sent — see below." }
        return "Log Bank SMS works and files card alerts in \(target.name). The test message was skipped on this iPhone, as non-card messages are."
    }
}
