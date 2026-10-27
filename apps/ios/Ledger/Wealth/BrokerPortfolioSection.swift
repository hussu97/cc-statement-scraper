import LedgerKit
import SwiftUI

/// A synced broker account's portfolio on its account screen: the value now (and in AED), the
/// last sync, the figures that matter (net deposits, profit, income, fees, cash, positions), the
/// value over time, the positions and those that ended. Shows nothing on an account with no sync.
/// A note opens its screen (`openNote`, the holding code). Every figure is the server's; the
/// words and what shows are LedgerKit's (`BrokerSection`, `BrokerPortfolioPresentation`).
struct BrokerPortfolioSection: View {
    let section: BrokerSection
    let retry: () -> Void
    let openNote: (String) -> Void

    var body: some View {
        switch section {
        case .hidden:
            EmptyView()
        case .loading:
            LoadingCard(label: "Loading the portfolio…")
        case .failed(let message):
            FailedCard(message: message, retry: retry)
        case .loaded(let p):
            BrokerHeaderCard(p: p)
            StatGrid(stats: p.stats)
            BrokerValueChartCard(chart: p.chart)
            BrokerPositionsCard(p: p, openNote: openNote)
            if !p.closed.isEmpty { BrokerClosedCard(rows: p.closed, openNote: openNote) }
        }
    }
}

/// The portfolio's value now, in AED, the prices' date and how the last sync went.
private struct BrokerHeaderCard: View {
    let p: BrokerPortfolioPresentation

    var body: some View {
        Card {
            SectionHeader(title: p.title, trailing: p.asOfText)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.totalText).font(Typography.display.monospacedDigit()).foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if let aed = p.totalAedText {
                    Text(aed).font(Typography.rowMeta).foregroundStyle(Palette.muted).moneyLine()
                }
            }
            .accessibilityElement(children: .combine)
            let sync = p.sync
            VStack(alignment: .leading, spacing: 2) {
                Label(sync.text, systemImage: sync.tone == .danger ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .font(Typography.caption)
                    .foregroundStyle(sync.tone == .neutral ? Palette.muted : sync.tone.color)
                if let detail = sync.detail {
                    Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
