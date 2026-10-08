import Foundation

/// What happened to one message handed to "Log Bank SMS".
public enum SMSIntakeOutcome: Equatable, Sendable {
    case dropped(SMSCapture.Decision)
    case noProfile
    /// Reached the server; `status` is `ingest_sms`'s per-message status.
    case delivered(status: String)
    /// Saved in the outbox; it will be retried.
    case queued(pending: Int)
    case failed(String)

    /// The short line Shortcuts shows. Never echoes the message.
    public var dialog: String {
        switch self {
        case .dropped(let decision): decision.userMessage
        case .noProfile: "Open Ledger and sign in first."
        case .delivered(let status): Self.statusMessage(status)
        case .queued: "Saved. It will be sent when you're back online."
        case .failed: "Couldn't save the message."
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
        case .queued: "queued"
        case .failed: "failed"
        }
    }

    static func statusMessage(_ status: String) -> String {
        switch status {
        case "unknown_card": "Logged. Ledger doesn't know this card yet — check Review."
        case "unparsed": "Logged. Ledger couldn't read this format yet."
        case "ignored": "Logged as not a credit-card purchase."
        case "duplicate_delivery", "already_linked": "Already logged."
        case "rejected_otp": "Skipped: one-time passcode."
        default: "Logged to Ledger."
        }
    }
}

/// The App Intent's whole decision path, kept here so `swift test` drives it
/// with a stub API: filter on the device → enqueue in the shared outbox →
/// try to deliver now. The message is persisted before any network call, so a
/// process killed mid-request loses nothing.
public struct SMSIntake: Sendable {
    let outbox: Outbox
    let profileCode: @Sendable () -> String?

    public init(outbox: Outbox, profileCode: @escaping @Sendable () -> String?) {
        self.outbox = outbox
        self.profileCode = profileCode
    }

    public func handle(body: String, sender: String?, receivedAt: Date = Date(),
                       clientMsgId: UUID = UUID()) async -> SMSIntakeOutcome {
        let (decision, payload) = SMSCapture.payload(body: body, sender: sender, receivedAt: receivedAt,
                                                     clientMsgId: clientMsgId)
        guard let payload else { return .dropped(decision) }
        guard let profile = profileCode() else { return .noProfile }
        do {
            try await outbox.enqueue(payload, profileCode: profile)
        } catch {
            return .failed(String(describing: type(of: error)))
        }
        let report = await outbox.flush()
        let wanted = payload.clientMsgId.uuidString.lowercased()
        if let result = report.results.first(where: { $0.clientMsgId.lowercased() == wanted }) {
            return .delivered(status: result.status)
        }
        return .queued(pending: max(report.remaining, 1))
    }
}
