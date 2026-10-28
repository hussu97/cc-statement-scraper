import LedgerKit
import SwiftUI

/// A Kite or Coin position: what it is, four figures (value with its price, P&L, today, share of
/// the account), its worth against its cost over time, the details, and its SIPs. The words are
/// LedgerKit's (`BrokerPositionPresentation`).
struct BrokerPositionView: View {
    let accountCode: String
    let isin: String
    let profileCode: String
    /// @State, not let: kept across the parent's re-renders.
    @State private var model: BrokerPositionModel

    init(model: BrokerPositionModel, accountCode: String, isin: String, profileCode: String) {
        self.accountCode = accountCode
        self.isin = isin
        self.profileCode = profileCode
        _model = State(initialValue: model)
    }

    var body: some View {
        Page {
            StateContainer(state: model.state, retry: reload) { detail in
                if let detail {
                    content(BrokerPositionPresentation(detail))
                } else {
                    EmptyCard(systemImage: "questionmark.circle", message: "This account has never reported a holding with ISIN \(isin).")
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(model.state.value.flatMap { $0 }.map { BrokerPositionPresentation($0).title } ?? "Holding")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.state.value == nil { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder private func content(_ p: BrokerPositionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let kind = p.kind { Text(kind.uppercased()).font(Typography.caption).tracking(0.8).foregroundStyle(Palette.muted) }
            Text(p.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Text(p.subtitle).font(Typography.caption).foregroundStyle(Palette.muted)
        }
        if let gone = p.noLongerHeldText {
            EmptyCard(systemImage: "checkmark.circle", message: gone)
        } else {
            Card {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
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
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        BrokerValueChartCard(chart: p.chart)
        if !p.facts.isEmpty {
            Card {
                SectionHeader(title: "Details")
                ForEach(p.facts) { fact in
                    if fact.id != p.facts.first?.id { Divider().overlay(Palette.border) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        Spacer(minLength: 12)
                        Text(fact.value).font(Typography.rowMeta).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        BrokerSipsCard(rows: p.sipRows)
    }

    private func load() async { await model.load(profileCode: profileCode, accountCode: accountCode, isin: isin) }
    private func reload() { Task { await load() } }
}
