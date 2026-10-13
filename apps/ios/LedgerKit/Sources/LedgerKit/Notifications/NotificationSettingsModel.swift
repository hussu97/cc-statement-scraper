import Foundation
import Observation

/// Settings → Notifications: one switch per `NoticeKind` and the system
/// permission. The app target reads and asks for the permission
/// (`UNUserNotificationCenter`) and withdraws what a switch turned off.
@MainActor
@Observable
public final class NotificationSettingsModel {
    public private(set) var permission: NoticePermission = .notDetermined
    private var values: [NoticeKind: Bool]
    private let preferences: NoticePreferences

    public init(preferences: NoticePreferences) {
        self.preferences = preferences
        values = Dictionary(uniqueKeysWithValues: NoticeKind.allCases.map { ($0, preferences.isOn($0)) })
    }

    public func isOn(_ kind: NoticeKind) -> Bool { values[kind] ?? true }

    /// Saves the switch. Returns the requests to withdraw when it was turned
    /// off (due reminders are withdrawn by the next `DueReminders.sync`).
    @discardableResult
    public func set(_ kind: NoticeKind, on: Bool) -> [String] {
        values[kind] = on
        preferences.set(kind, on: on)
        return on ? [] : CaptureNotices.cancelIDs(for: kind)
    }

    public func permissionChanged(_ permission: NoticePermission) { self.permission = permission }

    public var footer: String {
        switch permission {
        case .allowed:
            "Only what needs you: a card Bank Ledger doesn't know, captures that didn't send, and dues. Never the text of an SMS."
        case .notDetermined:
            "Allow notifications here or from Set up SMS capture. Bank Ledger never shows the text of an SMS in one."
        case .denied:
            "Notifications are off for Bank Ledger in iOS Settings → Notifications."
        }
    }
}
