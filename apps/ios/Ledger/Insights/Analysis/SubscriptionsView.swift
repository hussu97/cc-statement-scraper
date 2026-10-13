import LedgerKit
import SwiftUI

/// Every recurring charge Bank Ledger found, ended and dismissed ones too (web Insights ›
/// Subscriptions, BACKLOG PAR-12). Insights has already loaded `recurring_list`; this screen
/// shows all of it, worded by `SubscriptionList` (LedgerKit).
struct SubscriptionsView: View {
    let charges: [RecurringCharge]

    var body: some View {
        let list = SubscriptionList(charges)
        Page {
            if list.isEmpty {
                AnalysisEmptyCard(systemImage: "repeat", title: SubscriptionList.emptyTitle,
                                  message: SubscriptionList.emptyBody)
                    .padding(.top, 8)
            } else {
                Text(list.headline).font(Typography.caption).foregroundStyle(Palette.muted).padding(.top, 8)
                Card {
                    ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(Palette.border) }
                        SubscriptionRow(row: row)
                    }
                }
                Text(SubscriptionList.footnote).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .ledgerNavigation(SubscriptionList.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SubscriptionRow: View {
    let row: SubscriptionList.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(row.merchantName).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    if let badge = row.statusBadge { Chip(label: badge) }
                }
            } trailing: {
                Text(row.expectedLabel).font(Typography.amount).moneyLine()
            }
            Text(row.detail).font(Typography.caption).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.lastLabel).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit()
                if let change = row.priceChange { Chip(label: change.label, tone: change.tone) }
                Spacer(minLength: 8)
                Text(row.annualLabel).font(Typography.caption).foregroundStyle(Palette.ink2).monospacedDigit()
            }
            Text(row.whenLabel).font(Typography.caption)
                .foregroundStyle(row.isOverdue ? Palette.warn : Palette.muted)
        }
        .opacity(row.isActive ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}
