import LedgerKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let profileCode: String
    @State private var confirmClear = false

    private var settings: SettingsModel { model.settings }
    private var profiles: ProfileStore { model.profiles }

    var body: some View {
        List {
            Section("Ledger") {
                if let profile = profiles.selected {
                    LabeledContent("Showing") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(profile.name)
                            if let label = profiles.access(of: profile.profileCode).label {
                                Text(label).font(Typography.caption).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                if profiles.canSwitch {
                    Button("Switch ledger") { profiles.select(nil) }
                }
            }

            // The former Statements tab: cycles, uploads, PDFs waiting from the share sheet, logs.
            Section {
                NavigationLink(value: SettingsRoute.statements) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Statements", systemImage: "doc.text")
                        if let waiting = model.statements.waitingLabel {
                            Text(waiting).font(Typography.caption).foregroundStyle(Palette.warn)
                        }
                    }
                }
            } header: {
                Text("Cards & statements")
            } footer: {
                Text(profiles.canWrite
                     ? "Statement cycles, PDF uploads and their processing logs. Add PDFs with + there, or share them to “Add to Bank Ledger”."
                     : "Statement cycles, PDF uploads and their processing logs.")
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

            PrivacySection(lock: model.lock)

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
                if let note = settings.outboxStatus.awaitingLedgerNote {
                    Text(note).font(Typography.caption).foregroundStyle(Palette.warn)
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
                if settings.outboxStatus.waiting > 0 {
                    Button("Discard waiting messages", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("SMS")
            } footer: {
                Text(SMSAutomationGuide.privacyNote)
            }

            Section {
                NavigationLink {
                    CardPaymentGuideView()
                } label: {
                    Label("Set up card payments", systemImage: "wave.3.right")
                }
                NavigationLink {
                    CardWalletNamesView(api: model.services.api, profileCode: profileCode, canEdit: profiles.canWrite)
                } label: {
                    Label("Card names", systemImage: "creditcard")
                }
            } header: {
                Text("Card names for payment shortcut")
            } footer: {
                Text("“Log Card Payment” files a tap-to-pay payment, in its own currency, on the card with the name the shortcut passes. Payments go to the “SMS go to” ledger.")
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
                SignOutButton(model: model)
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
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .statements:
                StatementsView(model: model.statements, profileCode: profileCode, canUpload: profiles.canWrite)
            }
        }
        .task {
            await model.statements.refreshWaiting()
            await settings.refresh()
        }
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
