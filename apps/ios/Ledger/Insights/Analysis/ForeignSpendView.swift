import LedgerKit
import SwiftUI

/// Foreign-currency spending (web Insights › FX & travel, BACKLOG PAR-12): per currency, what
/// was spent there and in AED, and the rate effectively paid. Every figure is `fx_spend`'s.
struct ForeignSpendView: View {
    let range: AnalysisRange
    let profileCode: String
    @Environment(AnalysisScreens.self) private var screens
    @State private var loader: AnalysisLoader<AnalysisRange, [ForeignSpendRow]>?

    var body: some View {
        Page {
            Text(range.label()).font(Typography.caption).foregroundStyle(Palette.muted).padding(.top, 8)
            if let loader {
                StateContainer(state: loader.state, retry: reload) { rows in
                    if rows.isEmpty {
                        AnalysisEmptyCard(systemImage: "airplane", title: ForeignSpendRow.emptyTitle,
                                          message: ForeignSpendRow.emptyBody)
                    } else {
                        Card {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().overlay(Palette.border) }
                                CurrencyRow(row: row)
                            }
                        }
                        Text(ForeignSpendRow.footnote).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            } else {
                LoadingCard()
            }
        }
        .ledgerNavigation("Foreign currency")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AnalysisTaskKey(profileCode: profileCode, request: range)) {
            let l = loader ?? screens.foreignSpend()
            loader = l
            await l.loadIfNeeded(profileCode: profileCode, request: range)
        }
        .refreshable { await loader?.load(profileCode: profileCode, request: range) }
    }

    private func reload() {
        guard let loader else { return }
        Task { await loader.load(profileCode: profileCode, request: range) }
    }
}

private struct CurrencyRow: View {
    let row: ForeignSpendRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow(alignment: .firstTextBaseline) {
                Text(row.currency).font(Typography.rowTitle).foregroundStyle(Palette.ink)
            } trailing: {
                Text(row.amountAedLabel).font(Typography.amount).moneyLine()
            }
            AdaptiveRow(alignment: .firstTextBaseline) {
                Text(row.originalLabel).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
            } trailing: {
                if let rate = row.rateLabel {
                    Text(rate).font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(row.countLabel).font(Typography.caption).foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                if let estimate = row.estimateLabel { Chip(label: estimate, tone: .info) }
            }
            if let note = row.estimateNote {
                Text(note).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
