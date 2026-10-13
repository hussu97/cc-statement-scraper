import LedgerKit
import SwiftUI

// Rows and screens of Settings' SMS section (SettingsView embeds or pushes them).

/// A message that stopped retrying, with Retry and Delete.
struct ParkedRow: View {
    let message: ParkedMessage
    @Environment(BankCatalog.self) private var banks: BankCatalog?
    let target: SMSTarget?
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let bank = banks?.bankCode(forSender: message.sender) { BankLogo(bankCode: bank, size: 18) }
                Text(message.title()).font(Typography.rowTitle)
            }
            Text(message.preview).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(2)
            Text(message.reason).font(Typography.caption).foregroundStyle(Palette.danger)
            HStack {
                if message.canRetry {
                    Button(target.map { "Retry to \($0.name)" } ?? "Retry", action: retry)
                        .buttonStyle(.bordered).tint(Palette.accent)
                        .disabled(target == nil)
                }
                Button("Delete", role: .destructive, action: delete).buttonStyle(.bordered)
            }
            .font(Typography.rowMeta)
        }
        .padding(.vertical, 4)
    }
}

/// The last real runs of "Log Bank SMS": outcome, sender and length, never the text.
struct RecentCapturesView: View {
    let settings: SettingsModel

    var body: some View {
        List {
            Section {
                ForEach(Array(settings.recentCaptures.enumerated()), id: \.offset) { _, record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.label()).font(Typography.rowTitle)
                        if let input = record.input {
                            Text(input).font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("The last \(CaptureLog.recentLimit) messages the automation handed over. The text itself is never kept here.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("Recent captures")
        .task { await settings.refresh() }
    }
}

/// Runs the intent's path in-app with a synthetic one-time passcode.
struct SendTestButton: View {
    let settings: SettingsModel

    var body: some View {
        Button {
            Task { await settings.runTest() }
        } label: {
            HStack {
                Text("Send test")
                if settings.isTesting { Spacer(); ProgressView() }
            }
        }
        .disabled(settings.isTesting)
        if let test = settings.lastTest {
            Text(test.label()).font(Typography.caption)
                .foregroundStyle(test.outcome == "test_ok" ? Palette.positive : Palette.danger)
        }
    }
}

/// Step-by-step for the Shortcuts automation that feeds bank SMS to the app.
struct SMSSetupGuideView: View {
    let settings: SettingsModel
    @Environment(NotificationSettingsModel.self) private var notifications: NotificationSettingsModel?

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text("SMS capture").font(Typography.display)
                Text("iOS doesn't let apps read messages. A Shortcuts automation hands each bank SMS to Bank Ledger's “Log Bank SMS” action the moment it arrives.")
                    .font(Typography.body).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)

            GuideSteps(steps: SMSAutomationGuide.steps)

            ShortcutInputStrip(frames: SMSAutomationGuide.shortcutInputFrames)

            Card {
                Label("Privacy", systemImage: "lock").font(Typography.cardTitle)
                Text(SMSAutomationGuide.privacyNote).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }

            // Asked here, never at launch (N-1): this is where capture is set up.
            if let notifications {
                Card {
                    Label("Notifications", systemImage: "bell").font(Typography.cardTitle)
                    Text("Get a notification only when something needs you: an SMS for a card Bank Ledger doesn't know, or captures not sent after an hour. Never the text of a message.")
                        .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    NotificationPermissionRow(model: notifications)
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                }
            }

            Card {
                Label("Check it", systemImage: "checkmark.circle").font(Typography.cardTitle)
                Text("Last captured: \(settings.lastCapture?.label() ?? "not yet")")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                SendTestButton(settings: settings)
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
            }

            OpenShortcutsButton()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refresh() }
    }
}
