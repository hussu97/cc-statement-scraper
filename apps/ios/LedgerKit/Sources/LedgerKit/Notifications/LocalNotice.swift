import Foundation

/// The kinds of local notification Bank Ledger posts (BACKLOG N-1). Each has
/// its own switch in Settings → Notifications. Only outcomes the person can act
/// on notify: a routine "Logged" never does.
public enum NoticeKind: String, CaseIterable, Sendable, Identifiable {
    /// A captured SMS or payment named a card Bank Ledger doesn't know.
    case unknownCard
    /// Something has waited in the outbox for over an hour.
    case outboxStuck
    /// Signed out (or no ledger) while SMS or payments wait on the phone.
    case signedOut
    /// A statement is due in 3 days, or today, and isn't paid.
    case dueReminder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unknownCard: "Unknown cards"
        case .outboxStuck: "Messages not sent"
        case .signedOut: "Signed out with messages waiting"
        case .dueReminder: "Statement due dates"
        }
    }

    public var detail: String {
        switch self {
        case .unknownCard: "An SMS or payment for a card Bank Ledger doesn't know yet."
        case .outboxStuck: "SMS or payments still on this phone an hour after they were captured."
        case .signedOut: "A capture saved on this phone because you're signed out."
        case .dueReminder: "3 days before and on the due date, until the statement is paid."
        }
    }
}

/// One local notification to post or schedule. Never carries an SMS body or
/// a merchant: only counts, card names, bank and statement figures.
public struct LocalNotice: Sendable, Hashable, Identifiable {
    /// Also the request identifier: posting the same id replaces the earlier one.
    public let id: String
    public let kind: NoticeKind
    public let title: String
    public let body: String
    /// Nil: now. Otherwise the moment it should be delivered.
    public let fireAt: Date?
    /// Where a tap lands; nil opens the app as it was.
    public let link: AppLink?

    public init(id: String, kind: NoticeKind, title: String, body: String, fireAt: Date? = nil, link: AppLink? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.link = link
    }
}

/// What to change in the notification centre: post (or replace) these,
/// withdraw those (pending and delivered).
public struct NoticeUpdate: Sendable, Equatable {
    public var post: [LocalNotice]
    public var cancel: [String]

    public init(post: [LocalNotice] = [], cancel: [String] = []) {
        self.post = post
        self.cancel = cancel
    }

    public var isEmpty: Bool { post.isEmpty && cancel.isEmpty }
}

/// Settings → Notifications switches, in the App Group's defaults so the App
/// Intents (which run in the background) read the same ones. All on by
/// default: nothing is delivered until notifications are allowed, which the
/// SMS guide asks for.
public struct NoticePreferences: @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    static func key(_ kind: NoticeKind) -> String { "ledger.notify.\(kind.rawValue)" }

    public func isOn(_ kind: NoticeKind) -> Bool {
        defaults.object(forKey: Self.key(kind)) as? Bool ?? true
    }

    public func set(_ kind: NoticeKind, on: Bool) {
        defaults.set(on, forKey: Self.key(kind))
    }
}

/// Whether the system lets Bank Ledger notify, and what Settings says about it.
public enum NoticePermission: String, Sendable, Equatable {
    case notDetermined, denied, allowed

    public var label: String {
        switch self {
        case .notDetermined: "Not turned on yet"
        case .denied: "Off in iOS Settings"
        case .allowed: "On"
        }
    }

    /// The button beside the label, if any: ask, or send the person to iOS Settings.
    public var action: String? {
        switch self {
        case .notDetermined: "Allow notifications"
        case .denied: "Open iOS Settings"
        case .allowed: nil
        }
    }
}

/// Decides the capture notifications (N-1a). Pure: the app target applies the
/// result to `UNUserNotificationCenter`.
public enum CaptureNotices {
    public enum Capture: Sendable { case sms, payment(card: String) }

    static let unknownCardID = "ledger.unknown-card"
    static let signedOutID = "ledger.signed-out"
    static let outboxStuckID = "ledger.outbox-stuck"

    /// After "Log Bank SMS" / "Log Card Payment": an unknown card, or a capture
    /// saved while signed out, notifies now; the outbox reminder is (re)planned.
    public static func afterCapture(_ outcome: SMSIntakeOutcome, capture: Capture, outbox: OutboxStatus,
                                    preferences: NoticePreferences, now: Date = Date()) -> NoticeUpdate {
        var update = outboxReminder(outbox, preferences: preferences, now: now)
        switch outcome {
        case .delivered(status: "unknown_card") where preferences.isOn(.unknownCard):
            update.post.append(unknownCard(capture))
        case .queued(.signedOut), .queued(.noLedger):
            if preferences.isOn(.signedOut) { update.post.append(signedOut(waiting: outbox.waiting)) }
        default:
            break
        }
        return update
    }

    /// The "not sent after an hour" reminder: scheduled for an hour after the
    /// oldest capture still being retried, withdrawn once nothing is. Never
    /// re-posted for a time already past (the person has been told, or is in
    /// the app, where the Overview strip says it).
    public static func outboxReminder(_ status: OutboxStatus, preferences: NoticePreferences,
                                      now: Date = Date()) -> NoticeUpdate {
        guard preferences.isOn(.outboxStuck), status.pending > 0, let oldest = status.oldest else {
            return NoticeUpdate(cancel: [outboxStuckID])
        }
        let fireAt = oldest.addingTimeInterval(Outbox.staleAfter)
        guard fireAt > now else { return NoticeUpdate() }
        let count = status.pending == 1 ? "1 SMS or payment hasn't" : "\(status.pending) SMS or payments haven't"
        return NoticeUpdate(post: [LocalNotice(
            id: outboxStuckID, kind: .outboxStuck, title: "Not sent yet",
            body: "\(count) reached Bank Ledger for an hour. Open Settings → SMS to send or check them.",
            fireAt: fireAt, link: .settings)])
    }

    static func unknownCard(_ capture: Capture) -> LocalNotice {
        switch capture {
        case .sms:
            return LocalNotice(id: unknownCardID, kind: .unknownCard, title: "Card not recognised",
                        body: "A card alert was logged for a card Bank Ledger doesn't know yet. Open Review to add it.",
                        link: .review)
        case .payment(let raw):
            let card = WalletCapture.clean(raw, limit: WalletCapture.passNameLimit)
            return LocalNotice(id: unknownCardID, kind: .unknownCard, title: "Card not recognised",
                        body: "A payment was logged on “\(card)”, but no card has that name. Set it in Settings → Card names.",
                        link: .settings)
        }
    }

    static func signedOut(waiting: Int) -> LocalNotice {
        let what = waiting <= 1 ? "A capture is" : "\(waiting) captures are"
        return LocalNotice(id: signedOutID, kind: .signedOut, title: "Sign in to send",
                           body: "\(what) waiting on this phone. Open Bank Ledger and sign in to send them.")
    }

    /// A kind switched off in Settings: withdraw what it already scheduled.
    public static func cancelIDs(for kind: NoticeKind) -> [String] {
        switch kind {
        case .unknownCard: [unknownCardID]
        case .outboxStuck: [outboxStuckID]
        case .signedOut: [signedOutID]
        case .dueReminder: []   // `DueReminders.sync` withdraws them by prefix
        }
    }
}
