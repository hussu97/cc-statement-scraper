import LedgerKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var confirmClear = false

    private var settings: SettingsModel { model.settings }
    private var profiles: ProfileStore { model.profiles }

    var body: some View {
        List {
            Section("Ledger") {
                if let profile = profiles.selected {
                    LabeledContent("Showing", value: profile.name)
                }
                if profiles.canSwitch {
                    Button("Switch ledger") { profiles.select(nil) }
                }
            }

            Section("Account") {
                if case .signedIn(_, let email) = model.session.phase, let email {
                    LabeledContent("Signed in as", value: email)
                }
                NavigationLink {
                    PasskeysView(session: model.session)
                } label: {
                    Label("Passkeys", systemImage: "person.badge.key")
                }
            }

            smsTargetSection

            Section {
                NavigationLink("Set up SMS capture") { SMSSetupGuideView(settings: settings) }
                LabeledContent("Last captured") {
                    Text(settings.lastCapture?.label() ?? "Not yet")
                        .multilineTextAlignment(.trailing)
                }
                if !settings.recentCaptures.isEmpty {
                    NavigationLink("Recent captures") { RecentCapturesView(settings: settings) }
                }
                SendTestButton(settings: settings)
                LabeledContent("Outbox", value: settings.outboxStatus.summary)
                if let error = settings.outboxStatus.lastError, settings.outboxStatus.pending > 0 {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
                }
                Button {
                    Task { await settings.flush() }
                } label: {
                    HStack {
                        Text("Send now")
                        if settings.isFlushing { Spacer(); ProgressView() }
                    }
                }
                .disabled(settings.isFlushing)
                if let message = settings.flushMessage {
                    Text(message).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                if settings.outboxStatus.pending > 0 {
                    Button("Discard waiting messages", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("SMS")
            } footer: {
                Text(SMSAutomationGuide.privacyNote)
            }

            if !settings.parked.isEmpty {
                Section {
                    ForEach(settings.parked) { message in
                        ParkedRow(message: message, target: profiles.smsTarget) {
                            Task { await settings.retry(message, target: profiles.smsTarget) }
                        } delete: {
                            Task { await settings.delete(message) }
                        }
                    }
                } header: {
                    Text("Not sent")
                } footer: {
                    Text("These stopped retrying. Retry sends them to the “SMS go to” ledger; Delete removes them from this iPhone.")
                }
            }

            Section {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            }

            #if DEBUG
            Section("Debug") {
                LabeledContent("Supabase", value: model.services.config.supabaseURL.absoluteString)
                LabeledContent("Environment", value: model.services.config.environment)
                LabeledContent("Sentry", value: "Off (Debug build)")
                if model.session.sessionInMemoryOnly {
                    Text("Session kept in memory only: this build can't use the keychain. The SMS action and the share extension won't see it.")
                        .font(Typography.caption).foregroundStyle(Palette.warn)
                }
                Button("Crash (test Sentry)", role: .destructive) { Telemetry.crashForTesting() }
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .ledgerNavigation("Settings")
        .task { await settings.refresh() }
        .confirmationDialog("Discard messages that haven't reached Bank Ledger?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { Task { await settings.clearOutbox() } }
        }
    }

    @ViewBuilder private var smsTargetSection: some View {
        Section {
            let eligible = profiles.smsEligible
            if eligible.count > 1 {
                Picker("SMS go to", selection: Binding(
                    get: { profiles.smsTarget?.profileCode ?? "" },
                    set: { profiles.setSMSTarget($0) })) {
                    ForEach(eligible) { Text($0.name).tag($0.profileCode) }
                }
            } else if let target = profiles.smsTarget {
                LabeledContent("SMS go to", value: target.name)
            } else {
                Text("You don't own a ledger, so SMS and shared PDFs can't be filed. Create a ledger of your own to capture SMS.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.danger)
            }
        } header: {
            Text("SMS & shared PDFs")
        } footer: {
            Text("Card alerts and PDFs shared to “Add to Bank Ledger” are filed here, whichever ledger you are viewing. Only ledgers you own are listed.")
        }
    }
}

private struct ParkedRow: View {
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
                Button(target.map { "Retry to \($0.name)" } ?? "Retry", action: retry)
                    .buttonStyle(.bordered).tint(Palette.accent)
                    .disabled(target == nil)
                Button("Delete", role: .destructive, action: delete).buttonStyle(.bordered)
            }
            .font(Typography.rowMeta)
        }
        .padding(.vertical, 4)
    }
}

/// The last real runs of "Log Bank SMS": outcome, sender and length, never the text.
private struct RecentCapturesView: View {
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

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text("SMS capture").font(Typography.display)
                Text("iOS doesn't let apps read messages. A Shortcuts automation hands each bank SMS to Bank Ledger's “Log Bank SMS” action the moment it arrives.")
                    .font(Typography.body).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)

            ForEach(SMSAutomationGuide.steps) { step in
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.number)")
                            .font(.system(.title3, design: .serif))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(Palette.accentInk)
                            .frame(width: 32, height: 32)
                            .background(Palette.accent, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(Typography.cardTitle)
                            Text(step.detail).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }

            Card {
                Label("Privacy", systemImage: "lock").font(Typography.cardTitle)
                Text(SMSAutomationGuide.privacyNote).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }

            Card {
                Label("Check it", systemImage: "checkmark.circle").font(Typography.cardTitle)
                Text("Last captured: \(settings.lastCapture?.label() ?? "not yet")")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                SendTestButton(settings: settings)
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
            }

            Link(destination: URL(string: "shortcuts://")!) {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.refresh() }
    }
}
