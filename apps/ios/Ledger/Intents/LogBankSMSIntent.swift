import AppIntents
import LedgerKit

/// "Log Bank SMS" — run by a Shortcuts personal automation ("When I get a
/// message containing Card → Log Bank SMS (Message content, Sender)").
///
/// Runs without opening the app: iOS launches the app process in the
/// background, the session comes from the shared keychain, the profile from
/// the App Group ("SMS go to", an owned ledger). Every decision is in `SMSIntake` (LedgerKit), which
/// `swift test` drives with a stub API. The message is never logged and never
/// echoed in the result.
struct LogBankSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bank SMS"
    static let description = IntentDescription(
        "Sends a bank SMS to Bank Ledger, which works out what it is. One-time passcodes are dropped on this device.")
    static let openAppWhenRun = false
    static let isDiscoverable = true

    @Parameter(title: "Message", description: "The message text (Shortcut Input → Content).",
               inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(title: "Sender", description: "The sender (Shortcut Input → Sender). Optional.")
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$message) from \(\.$sender)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: "not_configured", dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let (outcome, dialog) = await services.smsIntake().handle(body: message, sender: sender)
        Telemetry.breadcrumb("sms_ingest", outcome: outcome.telemetryOutcome, data: ["entry": "intent"])
        // Saved but not sent (e.g. no data): ask iOS to send it once a connection is back.
        if case .queued = outcome { await BackgroundSync.schedule(services) }
        // Never opens the app: this runs in the background for every alert. A
        // review is named in the dialog (IOS-07r; README "Open URL ledger://review").
        return .result(value: outcome.telemetryOutcome, dialog: IntentDialog(stringLiteral: dialog))
    }
}

/// Makes the action appear in Shortcuts and Spotlight without setup.
struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogBankSMSIntent(),
            phrases: ["Log bank SMS in \(.applicationName)", "Send SMS to \(.applicationName)"],
            shortTitle: "Log Bank SMS",
            systemImageName: "message.badge")
        AppShortcut(
            intent: LogCardPaymentIntent(),
            phrases: ["Log card payment in \(.applicationName)", "Add card payment to \(.applicationName)"],
            shortTitle: "Log Card Payment",
            systemImageName: "creditcard")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
