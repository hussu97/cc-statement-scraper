import Foundation

/// "Log Card Payment"'s whole decision path, mirroring `SMSIntake` so
/// `swift test` drives it with a stub API: check on the device → enqueue in
/// the shared outbox → try to deliver now. Payments go to the same ledger as
/// SMS (`SMSTargetStore`) and reuse `SMSIntakeOutcome` and its wording. The
/// merchant is never logged or echoed.
public struct WalletIntake: Sendable {
    let outbox: Outbox
    let target: @Sendable () -> SMSTarget?
    let log: CaptureLog?

    public init(outbox: Outbox, target: @escaping @Sendable () -> SMSTarget?, log: CaptureLog? = nil) {
        self.outbox = outbox
        self.target = target
        self.log = log
    }

    /// Handles one payment as the intent receives it: the Wallet Amount as
    /// text (its currency comes with it) and the optional *Currency if
    /// missing*. `WalletAmount.resolve` decides.
    public func handle(amountText: String?, fallbackCurrency: String?, merchant: String, card: String,
                       locale: Locale = .current, occurredAt: Date = Date(),
                       clientMsgId: UUID = UUID()) async -> (outcome: SMSIntakeOutcome, dialog: String) {
        await handle(WalletAmount.resolve(text: amountText, fallbackCurrency: fallbackCurrency, locale: locale),
                     merchant: merchant, card: card, occurredAt: occurredAt, clientMsgId: clientMsgId)
    }

    /// Handles one payment and returns the outcome with the line to show.
    public func handle(amount: Decimal, currency: String, merchant: String, card: String,
                       occurredAt: Date = Date(), clientMsgId: UUID = UUID()) async -> (outcome: SMSIntakeOutcome, dialog: String) {
        await handle(.success(.init(amount: amount, currency: currency, source: .text)), merchant: merchant,
                     card: card, occurredAt: occurredAt, clientMsgId: clientMsgId)
    }

    private func handle(_ amount: Result<WalletAmount.Resolved, WalletCapture.Problem>, merchant: String, card: String,
                        occurredAt: Date, clientMsgId: UUID) async -> (outcome: SMSIntakeOutcome, dialog: String) {
        let destination = target()
        let checked = amount.flatMap {
            WalletCapture.payment(amount: $0.amount, currency: $0.currency, merchant: merchant, passName: card,
                                  occurredAt: occurredAt, clientMsgId: clientMsgId)
        }
        let outcome: SMSIntakeOutcome
        switch checked {
        case .failure(let problem):
            outcome = .refused(code: problem.rawValue, message: problem.userMessage)
        case .success(let payment):
            // No ledger yet: saved without one, like an SMS, and sent once one is known (IOS-12r).
            outcome = await SMSIntake.deliver(.wallet(payment), to: destination, outbox: outbox)
        }
        let passName = (try? checked.get())?.passName ?? ""
        let dialog = Self.dialog(outcome, ledger: destination?.name, card: passName)
        log?.record(CaptureRecord(at: occurredAt, outcome: "wallet_\(outcome.telemetryOutcome)",
                                  message: "Card payment: \(dialog)", isTest: false))
        return (outcome, dialog)
    }

    /// `SMSIntakeOutcome.dialog`, except where a payment needs other words: an
    /// unknown card means no card has this name yet, and only Settings fixes it.
    public static func dialog(_ outcome: SMSIntakeOutcome, ledger: String?, card: String) -> String {
        let to = ledger.map { "to \($0)" } ?? "to Ledger"
        switch outcome {
        case .delivered(status: "unknown_card"):
            return "Logged \(to), but no card is named “\(card)”. Open Ledger → Settings → Card names and give the card that name."
        case .queued(.noLedger):
            return "Saved on this phone, but no ledger is set for SMS and payments. Open Ledger, sign in and choose “SMS go to” to send it."
        case .failed:
            return "Couldn't save the payment on this phone."
        default:
            return outcome.dialog(ledger: ledger)
        }
    }
}
