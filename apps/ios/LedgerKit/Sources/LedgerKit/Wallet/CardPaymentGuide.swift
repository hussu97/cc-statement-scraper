import Foundation

/// Settings → Card names for payment shortcut → Set up card payments: the
/// Shortcuts Transaction automation that runs "Log Card Payment".
public enum CardPaymentGuide {
    public static let steps: [SMSAutomationGuide.Step] = [
        .init(number: 1, title: "Open Shortcuts → Automation",
              detail: "Tap + (New Automation) and choose Transaction."),
        .init(number: 2, title: "Choose your cards, When I Tap",
              detail: "Pick the cards whose payments to log, keep When I Tap, choose Run Immediately and tap Next."),
        .init(number: 3, title: "Add “Log Card Payment”",
              detail: "Create New Shortcut → search Ledger → Log Card Payment."),
        .init(number: 4, title: "Pass the payment",
              detail: "Tap Amount and choose Shortcut Input, then Amount. Its currency comes with it, so a payment abroad keeps its own. Set Merchant to Shortcut Input's Merchant and Card to its Card or Pass."),
        .init(number: 5, title: "Leave the currency to the payment",
              detail: "Under Show More, leave Currency if missing empty: it applies only to an amount that arrives without a currency. A shortcut set up earlier with Amount in a set currency still works but files every payment in that currency: set Amount as in step 4 and clear it."),
        .init(number: 6, title: "Name your cards",
              detail: "In Card names, type each card's name exactly as Wallet shows it. Until then, Shortcuts shows the name it passed and the payment waits for it."),
    ]
}
