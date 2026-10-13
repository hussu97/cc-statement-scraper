import AppIntents
import Foundation
import LedgerKit

/// "Log Card Payment" — run by a Shortcuts Transaction automation ("When I tap"
/// a card → Log Card Payment (Amount, Merchant, Card or Pass)).
///
/// Runs without opening the app, like "Log Bank SMS": the session comes from
/// the shared keychain, the ledger from the App Group ("SMS go to"), and the
/// payment waits in the same outbox when there is no connection. Every decision
/// is in `WalletIntake` / `WalletAmount` (LedgerKit). The merchant is never
/// logged and never echoed in the result.
///
/// The Amount is read as text (`"AED 12.50"`, `"€4.20"`), so the currency comes
/// from the transaction itself; an `IntentCurrencyAmount` would take it from a
/// picker fixed in the automation. `fallbackCurrency` applies only to an
/// amount without one.
///
/// App Store processing rejects intent text naming Apple products (ITMS-90626;
/// CLAUDE.md §5.6), so the title, description and parameters say "card".
struct LogCardPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Card Payment"
    static let description = IntentDescription(
        "Sends a card payment, in its own currency, to Bank Ledger, which files it on the card with that name.")
    static let openAppWhenRun = false
    static let isDiscoverable = true

    @Parameter(title: "Amount",
               description: "The payment amount with its currency (Shortcut Input → Amount).")
    var transactionAmount: String?

    @Parameter(title: "Merchant", description: "Where you paid (Shortcut Input → Merchant).")
    var merchant: String

    @Parameter(title: "Card", description: "The card's name (Shortcut Input → Card or Pass).")
    var card: String

    @Parameter(title: "Currency if missing",
               description: "Optional, e.g. AED. Used only when the amount arrives without a currency.")
    var fallbackCurrency: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$transactionAmount) at \(\.$merchant) on \(\.$card)") {
            \.$fallbackCurrency
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: "not_configured", dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let (outcome, dialog) = await services.walletIntake().handle(
            amountText: transactionAmount, fallbackCurrency: fallbackCurrency, merchant: merchant, card: card)
        Telemetry.breadcrumb("wallet_ingest", outcome: outcome.telemetryOutcome, data: ["entry": "intent"])
        // Saved but not sent (e.g. no data at the till): ask iOS to send it once a connection is back.
        if case .queued = outcome { await BackgroundSync.schedule(services) }
        // Only what needs the person notifies (unknown card, signed out, not sent in an hour).
        await LocalNotifications.afterCapture(outcome, capture: .payment(card: card), services: services)
        // Never opens the app: this runs in the background for every alert. A
        // review is named in the dialog (IOS-07r; README "Open URL ledger://review").
        return .result(value: outcome.telemetryOutcome, dialog: IntentDialog(stringLiteral: dialog))
    }
}
