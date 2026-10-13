import LedgerKit
import SwiftUI

/// Step-by-step for the Shortcuts Transaction automation that runs
/// "Log Card Payment". The steps are `CardPaymentGuide` (LedgerKit).
struct CardPaymentGuideView: View {
    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text("Card payments").font(Typography.display)
                Text("A Shortcuts automation hands each tap-to-pay payment to Bank Ledger's “Log Card Payment” action, with its amount, currency, merchant and card.")
                    .font(Typography.body).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)

            GuideSteps(steps: CardPaymentGuide.steps)

            Card {
                Label("Payments with an SMS alert", systemImage: "link").font(Typography.cardTitle)
                Text("A card that also sends SMS alerts is safe to add: Bank Ledger links the alert and the payment (same account, amount and currency, within 30 minutes) into one transaction.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }

            OpenShortcutsButton()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}
