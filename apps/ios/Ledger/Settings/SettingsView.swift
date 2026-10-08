import LedgerKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var confirmClear = false

    private var settings: SettingsModel { model.settings }

    var body: some View {
        List {
            Section("Ledger") {
                if let profile = model.profiles.selected {
                    LabeledContent("Profile", value: profile.name)
                }
                if model.profiles.canSwitch {
                    Button("Switch ledger") { model.profiles.select(nil) }
                }
                if case .signedIn(_, let email) = model.session.phase, let email {
                    LabeledContent("Signed in as", value: email)
                }
            }

            Section {
                NavigationLink("Set up SMS capture") { SMSSetupGuideView() }
                LabeledContent("Outbox", value: settings.outboxStatus.summary)
                if let error = settings.outboxStatus.lastError {
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
                if !settings.outboxStatus.isEmpty {
                    Button("Discard waiting messages", role: .destructive) { confirmClear = true }
                }
            } header: {
                Text("SMS")
            } footer: {
                Text(SMSAutomationGuide.privacyNote)
            }

            Section {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            }

            #if DEBUG
            Section("Debug") {
                LabeledContent("Supabase", value: model.services.config.supabaseURL.absoluteString)
                LabeledContent("Environment", value: model.services.config.environment)
                Button("Crash (test Sentry)", role: .destructive) { Telemetry.crashForTesting() }
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .ledgerNavigation("Settings")
        .task { await settings.refresh() }
        .confirmationDialog("Discard messages that haven't reached Ledger?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { Task { await settings.clearOutbox() } }
        }
    }
}

/// Step-by-step for the Shortcuts automation that feeds bank SMS to the app.
struct SMSSetupGuideView: View {
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text("SMS capture").font(Typography.display)
                Text("iOS doesn't let apps read messages. A Shortcuts automation hands each bank SMS to Ledger's “Log Bank SMS” action the moment it arrives.")
                    .font(Typography.body).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)

            ForEach(SMSAutomationGuide.steps) { step in
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.number)")
                            .font(.system(.title3, design: .serif))
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

            Link(destination: URL(string: "shortcuts://")!) {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
