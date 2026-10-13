import LedgerKit
import UIKit
@preconcurrency import UserNotifications

/// Plumbing for local notifications (BACKLOG N-1): LedgerKit decides what to
/// post (`CaptureNotices`, `DueReminders`); this applies it to
/// `UNUserNotificationCenter`. Permission is asked only from the SMS guide or
/// Settings → Notifications, never at launch. Nothing here sees an SMS body.
enum LocalNotifications {
    private static var center: UNUserNotificationCenter { .current() }
    static let linkKey = "ledger.link"

    // MARK: Permission

    static func permission() async -> NoticePermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    /// Asks once; afterwards iOS answers from the person's earlier choice.
    static func requestPermission() async -> NoticePermission {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    // MARK: Applying LedgerKit's decisions

    static func apply(_ update: NoticeUpdate) async {
        guard !update.isEmpty else { return }
        if !update.cancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: update.cancel)
            center.removeDeliveredNotifications(withIdentifiers: update.cancel)
        }
        guard !update.post.isEmpty, await permission() == .allowed else { return }
        for notice in update.post {
            try? await center.add(request(for: notice))
        }
    }

    static func request(for notice: LocalNotice) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.kind.rawValue
        if let link = notice.link { content.userInfo = [linkKey: link.url.absoluteString] }
        var trigger: UNNotificationTrigger?
        if let fireAt = notice.fireAt {
            let interval = fireAt.timeIntervalSinceNow
            if interval > 0 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) }
        }
        return UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger)
    }

    // MARK: Entry points

    /// After an App Intent's outcome: an unknown card or a capture saved while
    /// signed out notifies; the "not sent after an hour" reminder is replanned.
    static func afterCapture(_ outcome: SMSIntakeOutcome, capture: CaptureNotices.Capture,
                             services: LedgerServices) async {
        let status = await services.outbox.status()
        await apply(CaptureNotices.afterCapture(outcome, capture: capture, outbox: status,
                                                preferences: services.notices))
    }

    /// After a flush (foreground, background task): withdraws the outbox
    /// reminder once nothing waits, or moves it to the new oldest capture.
    static func refreshOutbox(_ services: LedgerServices) async {
        let status = await services.outbox.status()
        await apply(CaptureNotices.outboxReminder(status, preferences: services.notices))
    }

    /// Applies `DueReminders.refresh`: replans from the ledger's statement
    /// cycles, withdraws everything once signed out, or (profiles not loaded
    /// yet) leaves what is scheduled. A failed load changes nothing either.
    static func refreshDueReminders(_ services: LedgerServices, _ refresh: DueReminders.Refresh) async {
        switch refresh {
        case .keep:
            return
        case .withdrawAll:
            await withdrawDueReminders()
        case .replan(let profileCode):
            let cycles: [StatementCycle]
            if services.notices.isOn(.dueReminder) {
                guard let loaded = try? await services.api.statementCycles(profileCode: profileCode,
                                                                            limit: DueReminders.cycleLimit) else { return }
                cycles = loaded
            } else {
                cycles = []
            }
            let planned = DueReminders.plan(cycles: cycles, preferences: services.notices)
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let delivered = await center.deliveredNotifications().map(\.request.identifier)
            await apply(DueReminders.sync(pendingIDs: pending, deliveredIDs: delivered, planned: planned,
                                          cycles: cycles))
        }
    }

    /// Signed out: every due reminder, scheduled or delivered, is withdrawn.
    static func withdrawDueReminders() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        await apply(DueReminders.withdrawAll(pendingIDs: pending, deliveredIDs: delivered))
    }
}

/// Shows a notice that arrives while the app is open, and routes a tap to its
/// `ledger://` link (LedgerKit `AppLink`).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    /// Set by the app once its model exists; called on the main actor.
    @MainActor var open: ((URL) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo[LocalNotifications.linkKey] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run { open?(url) }
    }
}
