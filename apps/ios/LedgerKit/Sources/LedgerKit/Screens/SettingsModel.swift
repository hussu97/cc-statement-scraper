import Foundation
import Observation

/// Settings tab: the SMS outbox and the automation guide.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var outboxStatus = OutboxStatus(pending: 0, oldest: nil, nextAttemptAt: nil, lastError: nil)
    public private(set) var isFlushing = false
    public var flushMessage: String?
    private let outbox: Outbox

    public init(outbox: Outbox) { self.outbox = outbox }

    public func refresh() async {
        outboxStatus = await outbox.status()
    }

    /// Sends everything now, ignoring backoff.
    public func flush() async {
        isFlushing = true
        defer { isFlushing = false }
        let report = await outbox.flush(force: true)
        flushMessage = Self.describe(report)
        await refresh()
    }

    public func clearOutbox() async {
        try? await outbox.removeAll()
        await refresh()
    }

    nonisolated static func describe(_ report: FlushReport) -> String {
        if report.sent == 0 && report.failed == 0 { return "Nothing to send." }
        if let error = report.error, report.sent == 0 { return "Couldn't send: \(error.description)" }
        if report.failed > 0 { return "Sent \(report.sent), \(report.failed) will retry." }
        return report.sent == 1 ? "Sent 1 message." : "Sent \(report.sent) messages."
    }
}

/// The in-app guide for the one supported way iOS hands SMS to an app: a
/// Shortcuts personal automation that runs "Log Bank SMS".
public enum SMSAutomationGuide {
    public struct Step: Identifiable, Sendable, Hashable {
        public var id: Int { number }
        public let number: Int
        public let title: String
        public let detail: String
    }

    /// Keywords for "Message contains". One automation per keyword — Shortcuts
    /// matches a single phrase per automation.
    public static let keywords = ["AED", "Card", "ending"]

    public static let steps: [Step] = [
        Step(number: 1, title: "Open Shortcuts → Automation",
             detail: "Tap + (New Automation) and choose Message."),
        Step(number: 2, title: "Message contains “AED”",
             detail: "Leave Sender empty (bank senders are names, not contacts). Set Message Contains to AED."),
        Step(number: 3, title: "Run Immediately",
             detail: "Choose Run Immediately and turn off Notify When Run, then tap Next."),
        Step(number: 4, title: "Add “Log Bank SMS”",
             detail: "Create New Shortcut → search Ledger → Log Bank SMS."),
        Step(number: 5, title: "Pass the message",
             detail: "Set Message to the Shortcut Input's Content, and Sender to the Shortcut Input's Sender."),
        Step(number: 6, title: "Repeat for “Card” and “ending”",
             detail: "Some banks write amounts without AED. Duplicates are harmless — Ledger de-duplicates by message."),
        Step(number: 7, title: "Test it",
             detail: "Ask a friend to text you “AED 1.00 test card ending 0000”. It should appear under Settings → Outbox or as an unparsed SMS."),
    ]

    public static let privacyNote = """
    Ledger drops one-time passcodes and debit-card or account alerts on the phone; \
    they never leave it. Only credit-card messages are sent, over your signed-in session.
    """
}
