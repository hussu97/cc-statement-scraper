import Foundation
import Observation

/// Settings tab: the SMS outbox (waiting and parked messages), the last
/// capture, the in-app test and the automation guide.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var outboxStatus = OutboxStatus()
    public private(set) var parked: [ParkedMessage] = []
    public private(set) var lastCapture: CaptureRecord?
    /// The last `CaptureLog.recentLimit` real captures, newest first.
    public private(set) var recentCaptures: [CaptureRecord] = []
    public private(set) var lastTest: CaptureRecord?
    public private(set) var isFlushing = false
    public private(set) var isTesting = false
    public var flushMessage: String?
    private let outbox: Outbox
    private let intake: SMSIntake?
    private let log: CaptureLog?

    public init(outbox: Outbox, intake: SMSIntake? = nil, log: CaptureLog? = nil) {
        self.outbox = outbox
        self.intake = intake
        self.log = log
    }

    public func refresh() async {
        outboxStatus = await outbox.status()
        let user = outbox.currentUser
        parked = await outbox.parkedEntries().map { ParkedMessage($0, currentUser: user) }
        lastCapture = log?.last
        recentCaptures = log?.recent ?? []
        lastTest = log?.lastTest
    }

    /// Sends everything now, ignoring backoff.
    public func flush() async {
        isFlushing = true
        defer { isFlushing = false }
        let report = await outbox.flush(force: true)
        flushMessage = Self.describe(report)
        await refresh()
    }

    /// "Send test": the intent's path with a synthetic one-time passcode.
    public func runTest() async {
        guard let intake else { return }
        isTesting = true
        defer { isTesting = false }
        _ = await intake.selfTest()
        await refresh()
    }

    /// Puts a parked message back in the queue, filed in `target` (the current
    /// "SMS go to" ledger), and tries it now.
    public func retry(_ message: ParkedMessage, target: SMSTarget?) async {
        try? await outbox.retry([message.id], reassignTo: target?.profileCode)
        let report = await outbox.flush(force: true)
        flushMessage = Self.describe(report)
        await refresh()
    }

    public func delete(_ message: ParkedMessage) async {
        try? await outbox.remove([message.id])
        await refresh()
    }

    public func clearOutbox() async {
        try? await outbox.removeAll()
        await refresh()
    }

    nonisolated static func describe(_ report: FlushReport) -> String {
        let accepted = report.sent - report.parked.count
        if report.sent == 0 && report.failed == 0 { return "Nothing to send." }
        if !report.parked.isEmpty {
            let n = report.parked.count
            let prefix = accepted > 0 ? "Sent \(accepted). " : ""
            return prefix + (n == 1 ? "1 message couldn't be sent — see below." : "\(n) messages couldn't be sent — see below.")
        }
        if let error = report.error, accepted == 0 { return "Couldn't send: \(error.description)" }
        if report.failed > 0 { return "Sent \(accepted), \(report.failed) will retry." }
        return accepted == 1 ? "Sent 1 message." : "Sent \(accepted) messages."
    }
}

/// A message or card payment that stopped retrying, as Settings lists it. Shows a short
/// preview so the user can tell messages apart; it never leaves the phone.
public struct ParkedMessage: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sender: String
    public let receivedAt: Date
    public let preview: String
    public let reason: String
    public let profileCode: String?
    /// Retry may send it to this account's "SMS go to" ledger: false for one
    /// captured under another account on this phone, which can only be deleted.
    public let canRetry: Bool

    /// `currentUser`: the account signed in now (`DeviceUserStore`).
    public init(_ entry: OutboxEntry, currentUser: String? = nil) {
        canRetry = !entry.isOtherAccounts && entry.belongs(to: currentUser)
        id = entry.id
        receivedAt = entry.item.capturedAt
        let text: String
        switch entry.item {
        case .sms(let p):
            sender = p.sender.isEmpty ? "Unknown sender" : p.sender
            text = p.body
        case .wallet(let p):
            sender = "Card payment · \(p.passName)"
            text = p.summary
        }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        preview = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
        reason = entry.parkedReason ?? entry.lastError ?? "Not sent."
        profileCode = entry.profileCode
    }

    /// `"ADCBAlert · 8 Oct"`.
    public func title(today: CalendarDay = LedgerDates.today()) -> String {
        "\(sender) · \(LedgerDates.dayLabel(CalendarDay(date: receivedAt), today: today))"
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

    /// The single "Message contains" keyword. Every credit-card purchase,
    /// refund and decline alert from ADCB ("Cr.Card", "Credit Card"), FAB
    /// ("Credit Card Purchase / Card No"), Emirates NBD ("Credit Card ending",
    /// refunds "your card ending") and SIB ("Covered Card") contains it, so one
    /// automation fires once per alert. Several keywords would fire the
    /// action two or three times for the same message.
    public static let keywords = ["Card"]

    public static let steps: [Step] = [
        Step(number: 1, title: "Open Shortcuts → Automation",
             detail: "Tap + (New Automation) and choose Message."),
        Step(number: 2, title: "Message contains “Card”",
             detail: "Leave Sender empty (bank senders are names, not contacts). Set Message Contains to Card. Create only this one automation: every credit-card alert from ADCB, FAB, Emirates NBD and SIB contains “Card”."),
        Step(number: 3, title: "Run Immediately, keep Notify When Run on",
             detail: "Choose Run Immediately and leave Notify When Run ON, so you see what Ledger did with each message (logged, unknown card, waiting). Tap Next."),
        Step(number: 4, title: "Add “Log Bank SMS”",
             detail: "Create New Shortcut → search Ledger → Log Bank SMS."),
        Step(number: 5, title: "Pass the message",
             detail: "Tap Message and choose Shortcut Input, then Content. Set Sender to Shortcut Input's Sender."),
        Step(number: 6, title: "Check it",
             detail: "Tap Send test below to check the action and your sign-in. After your next card purchase, “Last captured” shows what happened, and Recent captures shows the sender and length the Shortcut passed."),
    ]

    public static let privacyNote = """
    Bank Ledger drops one-time passcodes on the phone; they never leave it. Every other \
    message the automation hands over is sent over your signed-in session, and Bank Ledger \
    files debit-card, account and other non-purchase alerts as ignored.
    """
}
