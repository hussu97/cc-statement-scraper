import LedgerKit
import SwiftUI

/// Settings → Privacy: the optional "Require Face ID" lock (`AppLock`, BACKLOG IOS-22).
struct PrivacySection: View {
    let lock: AppLock

    var body: some View {
        Section {
            Toggle(lock.settingTitle, isOn: Binding(
                get: { lock.requireAuth },
                set: { on in Task { await lock.setRequireAuth(on) } }))
                .disabled(lock.isAuthenticating)
            if let message = lock.message {
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(AppLock.footer)
        }
    }
}
