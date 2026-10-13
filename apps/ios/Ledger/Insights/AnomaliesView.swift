import LedgerKit
import SwiftUI

/// Unusual spending (PAR-9, the web's Insights → Anomalies) over the Insights period: charges far
/// above the usual at their merchant or in their category, and large first purchases, each in one
/// plain sentence from the server's figures. A row opens the transaction; owners mark one
/// "This is fine" so it is never flagged again.
struct AnomaliesView: View {
    let profileCode: String
    let from: CalendarDay
    let to: CalendarDay
    /// Owners only (`dismiss_anomaly` asserts the owner role).
    let canMarkFine: Bool
    @Environment(AnomaliesModel.self) private var model
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Page {
            Text(LedgerDates.rangeLabel(from: from, to: to))
                .font(Typography.caption).foregroundStyle(Palette.muted)
                .padding(.top, 8)
            if let message = model.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            StateContainer(state: model.state, retry: reload) { rows in
                Card {
                    SectionHeader(title: AnomaliesModel.title(count: rows.count))
                    if rows.isEmpty {
                        Label(AnomaliesModel.emptyTitle, systemImage: "checkmark.shield")
                            .font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(AnomaliesModel.emptyDetail).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    }
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                        AnomalyRow(row: row, working: model.working == row.txnCode,
                                   open: { tabs?.openTransaction(row.txnCode) },
                                   markFine: canMarkFine ? { Task { await model.markFine(row, profileCode: profileCode) } } : nil)
                    }
                    if !rows.isEmpty {
                        Text(AnomaliesModel.footnote).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .ledgerNavigation("Unusual spending")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: [from, to]) { await model.loadIfNeeded(profileCode: profileCode, from: from, to: to) }
        .refreshable { await model.load(profileCode: profileCode, from: from, to: to) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode, from: from, to: to) } }
}

private struct AnomalyRow: View {
    let row: Anomaly
    let working: Bool
    let open: () -> Void
    let markFine: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    AdaptiveRow {
                        Text(row.name).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    } trailing: {
                        Text(MoneyFormat.aed(row.amount)).font(Typography.amount).foregroundStyle(Palette.ink)
                    }
                    HStack(spacing: 6) {
                        Text(LedgerDates.dayLabel(row.txnDate)).font(Typography.caption).foregroundStyle(Palette.muted)
                        Chip(label: row.reasonLabel, tone: .warn)
                    }
                    Text(row.explanation).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the transaction in Activity")
            if let markFine {
                if working {
                    ProgressView()
                } else {
                    Button(action: markFine) {
                        Label("This is fine", systemImage: "checkmark")
                            .font(Typography.rowMeta)
                            .frame(minHeight: Metrics.tapMin)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                    .accessibilityLabel("This is fine: \(row.name)")
                }
            }
        }
    }
}
