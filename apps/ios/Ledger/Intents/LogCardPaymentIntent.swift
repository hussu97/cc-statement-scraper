import AppIntents
import LedgerKit

/// "Log Card Payment" — run by a Shortcuts Transaction automation ("When I tap"
/// a card → Log Card Payment (Amount, Merchant, Card or Pass)).
///
/// Runs without opening the app, like "Log Bank SMS": the session comes from
/// the shared keychain, the ledger from the App Group ("SMS go to"), and the
/// payment waits in the same outbox when there is no connection. Every decision
/// is in `WalletIntake` (LedgerKit). The amount arrives as a currency amount
/// (a `Decimal` and a currency code), never as formatted text. The merchant is
/// never logged and never echoed in the result.
///
/// App Store processing rejects intent text naming Apple products (ITMS-90626;
/// CLAUDE.md §5.6), so the title, description and parameters say "card".
struct LogCardPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Card Payment"
    static let description = IntentDescription(
        "Sends a card payment to Bank Ledger, which files it on the card with that name.")
    static let openAppWhenRun = false
    static let isDiscoverable = true

    @Parameter(title: "Amount", description: "The payment amount (Shortcut Input → Amount).")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Merchant", description: "Where you paid (Shortcut Input → Merchant).")
    var merchant: String

    @Parameter(title: "Card", description: "The card's name (Shortcut Input → Card or Pass).")
    var card: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant) on \(\.$card)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: "not_configured", dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let (outcome, dialog) = await services.walletIntake().handle(
            amount: amount.amount, currency: amount.currencyCode, merchant: merchant, card: card)
        Telemetry.breadcrumb("wallet_ingest", outcome: outcome.telemetryOutcome, data: ["entry": "intent"])
        // Saved but not sent (e.g. no data at the till): ask iOS to send it once a connection is back.
        if case .queued = outcome { await BackgroundSync.schedule(services) }
        return .result(value: outcome.telemetryOutcome, dialog: IntentDialog(stringLiteral: dialog))
    }
}
