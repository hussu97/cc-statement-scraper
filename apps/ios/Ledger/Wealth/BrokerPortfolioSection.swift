import LedgerKit
import SwiftUI

/// A broker account's portfolio while it isn't on screen yet: its loading and failure on a broker
/// account (Swissquote), nothing on any other. Once loaded, the account screen lays the portfolio
/// out itself (`BrokerSummaryCard`, the chart and the tabs). What shows is `BrokerSection`'s.
struct BrokerPortfolioStatus: View {
    let section: BrokerSection
    let retry: () -> Void

    var body: some View {
        switch section {
        case .loading: LoadingCard(label: "Loading the portfolio…")
        case .failed(let message): FailedCard(message: message, retry: retry)
        case .hidden, .loaded: EmptyView()
        }
    }
}

/// The three numbers a broker account leads with (total value with AED under it, profit on what
/// was put in, cash) and how fresh they are, in one small line.
struct BrokerSummaryCard: View {
    let p: BrokerPortfolioPresentation

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                ForEach(p.figures) { figure in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(figure.label.uppercased()).font(Typography.caption).tracking(0.8).foregroundStyle(Palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(figure.value).font(Typography.amountLarge)
                            .foregroundStyle(figure.tone == .neutral ? Palette.ink : figure.tone.color).moneyLine()
                        if let sub = figure.sub {
                            Text(sub).font(Typography.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityElement(children: .combine)
                }
            }
            let sync = p.sync
            VStack(alignment: .leading, spacing: 2) {
                Label(sync.text, systemImage: sync.tone == .neutral ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(sync.tone == .neutral ? Palette.muted : sync.tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = sync.detail {
                    Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
