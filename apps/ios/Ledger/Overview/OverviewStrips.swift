import LedgerKit
import SwiftUI

/// SMS stuck on this phone for over an hour (`OutboxStatus.staleAlert`); opens Settings.
struct OutboxStrip: View {
    let alert: StaleOutboxAlert
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.full").foregroundStyle(Palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(alert.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Settings")
    }
}

/// Overview's latest transactions; each opens its sheet in Activity.
struct RecentCard: View {
    let recent: [Overview.RecentTransaction]
    /// Opens the transaction's sheet in Activity.
    let open: (Overview.RecentTransaction) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Latest")
            if recent.isEmpty {
                Text("No transactions yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(recent) { txn in
                Button { open(txn) } label: { recentRow(txn) }.buttonStyle(.plain)
            }
        }
    }

    private func recentRow(_ txn: Overview.RecentTransaction) -> some View {
        AdaptiveRow(alignment: .center) {
            HStack(spacing: 8) {
                CategoryDot(token: txn.categoryColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(txn.title).font(Typography.rowTitle).lineLimit(2)
                    Text(LedgerDates.relativeDayLabel(txn.txnDate)).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(txn.amountLabel).font(Typography.amount).moneyLine()
                    .foregroundStyle(txn.isCredit ? Palette.positive : Palette.ink)
                Text(txn.badge.label).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
