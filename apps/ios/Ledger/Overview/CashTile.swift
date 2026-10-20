import LedgerKit
import SwiftUI

/// Overview's cash tile (Phase 2d): the server's AED total across the bank accounts, how fresh
/// it is and what it can't vouch for. Tapping opens Cash & accounts.
struct CashTile: View {
    let position: CashPosition
    let cash: CashModel
    let profileCode: String
    let canEdit: Bool

    var body: some View {
        NavigationLink {
            CashView(model: cash, profileCode: profileCode, canEdit: canEdit)
        } label: {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cash").font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(position.accounts.count == 1 ? "1 account" : "\(position.accounts.count) accounts")
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    // Full size: a short figure that `moneyLine`'s shrink-to-fit made small beside a wrapped caveat.
                    Text(position.totalText).font(Typography.amountLarge).foregroundStyle(Palette.ink)
                        .monospacedDigit().lineLimit(1).fixedSize()
                    if let asOf = position.asOfText() {
                        Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                ForEach(position.caveats, id: \.self) { caveat in
                    Label(caveat, systemImage: position.caveatTone == .warn ? "exclamationmark.triangle" : "clock")
                        .font(Typography.caption)
                        .foregroundStyle(position.caveatTone == .warn ? Palette.warn : Palette.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Cash and accounts")
    }
}
