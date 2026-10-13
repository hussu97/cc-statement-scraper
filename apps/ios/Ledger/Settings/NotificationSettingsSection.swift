import LedgerKit
import SwiftUI
import UIKit

/// Settings → Notifications: the permission and one switch per kind (N-1).
/// Decisions are in `NotificationSettingsModel`, `CaptureNotices` and `DueReminders`.
struct NotificationSettingsSection: View {
    let services: LedgerServices
    let profileCode: String
    @Environment(NotificationSettingsModel.self) private var model: NotificationSettingsModel?

    var body: some View {
        if let model { section(model) }
    }

    private func section(_ model: NotificationSettingsModel) -> some View {
        Section {
            NotificationPermissionRow(model: model)
            ForEach(NoticeKind.allCases) { kind in
                Toggle(isOn: Binding(get: { model.isOn(kind) }, set: { set(kind, on: $0, model: model) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                .tint(Palette.accent)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(model.footer)
        }
    }

    private func set(_ kind: NoticeKind, on: Bool, model: NotificationSettingsModel) {
        let withdraw = model.set(kind, on: on)
        Task {
            await LocalNotifications.apply(NoticeUpdate(cancel: withdraw))
            switch kind {
            case .dueReminder: await LocalNotifications.refreshDueReminders(services, profileCode: profileCode)
            case .outboxStuck: await LocalNotifications.refreshOutbox(services)
            default: break
            }
        }
    }
}

/// "Notifications: On", or a button to allow them (or to open iOS Settings
/// once declined). Used by Settings and the SMS guide.
struct NotificationPermissionRow: View {
    let model: NotificationSettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent("Notifications", value: model.permission.label)
            .task { model.permissionChanged(await LocalNotifications.permission()) }
        if let action = model.permission.action {
            Button(action) {
                Task {
                    if model.permission == .denied {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    } else {
                        model.permissionChanged(await LocalNotifications.requestPermission())
                    }
                }
            }
        }
    }
}
