import LedgerKit
import SwiftUI

/// Wealth's Overview: net worth (bank cash + investments − what the cards owe) with how complete it
/// is, net worth over time, the bank accounts (each opening its ledger), the gold and silver, what
/// each card owes, this month's cash flow and the bank-account insights. Every figure is the server's.
struct WealthOverviewView: View {
    let model: WealthOverviewModel
    let profileCode: String
    let canEdit: Bool
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Page {
            StateContainer(state: model.state, retry: reload) { content in
                NetWorthHero(netWorth: content.netWorth)
                if !content.insights.isEmpty {
                    WealthInsightsCard(insights: content.insights, profileCode: profileCode, canEdit: canEdit) {
                        insight in Task { await model.dismiss(insight, profileCode: profileCode) }
                    }
                }
                NetWorthChartCard(points: content.series)
                Card {
                    SectionHeader(title: "Bank accounts", trailing: content.position.map { $0.totalText })
                    if let position = content.position {
                        if position.accounts.isEmpty {
                            Text(CashPosition.noAccountsMessage(canEdit: canEdit))
                                .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        }
                        ForEach(position.accounts) { account in
                            if account.id != position.accounts.first?.id { Divider().overlay(Palette.border) }
                            BankAccountRow(account: account, profileCode: profileCode, canEdit: canEdit)
                        }
                    } else {
                        Text("Couldn't load the accounts. Pull to refresh.")
                            .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    }
                    LinkRow(title: "Manage accounts") { tabs?.show(.accounts) }
                }
                InvestmentsSummaryCard(valuation: content.investments, canEdit: canEdit) { tabs?.show(.investments) }
                OwedCard(netWorth: content.netWorth, cards: content.owingCards)
                if let month = content.thisMonth {
                    ThisMonthCard(month: month, title: model.monthTitle) { tabs?.show(.cashFlow) }
                }
            }
            .padding(.top, 8)
        }
        .rootNavigation("Overview")
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

private struct NetWorthHero: View {
    let netWorth: NetWorth
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Typography.heroBaseSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NET WORTH").font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { unit; amount }
                    VStack(alignment: .leading, spacing: 0) { unit; amount }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(netWorth.heroAccessibilityLabel)
            Chip(label: netWorth.completenessText, tone: netWorth.completenessTone)
            VStack(alignment: .leading, spacing: 4) {
                line("Cash in bank accounts", netWorth.cashText)
                if netWorth.showsHoldings { line("Investments", netWorth.holdingsAdditionText) }
                line("Owed on cards", netWorth.owedDeductionText)
            }
            if let asOf = netWorth.asOfText() {
                Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            ForEach(netWorth.caveats, id: \.self) { caveat in
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption).foregroundStyle(Palette.warn)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
        }
        .accessibilityElement(children: .combine)
    }

    private var unit: some View {
        Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
    }

    private var amount: some View {
        Text(netWorth.heroAmount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.4)
    }
}

/// The gold and silver: the server's value, gain and 24-hour change; opens the Investments tab.
private struct InvestmentsSummaryCard: View {
    let valuation: HoldingsValuation?
    let canEdit: Bool
    let open: () -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Investments", trailing: valuation.flatMap { $0.isEmpty ? nil : $0.valueText })
            if let valuation {
                if valuation.isEmpty {
                    Text(HoldingsValuation.emptyMessage(canEdit: canEdit))
                        .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                } else {
                    row("Gold and silver", valuation.countText, Palette.ink)
                    row("Gain", valuation.gainText ?? "Add what you paid",
                        valuation.gainText == nil ? Palette.muted : valuation.gainTone.color)
                    if let change = valuation.changeText { row("Last 24 hours", change, valuation.changeTone.color) }
                    ForEach(valuation.caveats, id: \.self) { caveat in
                        Text(caveat).font(Typography.caption).foregroundStyle(Palette.warn)
                    }
                }
            } else {
                Text("Couldn't load the investments. Pull to refresh.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            LinkRow(title: "See investments", action: open)
        }
    }

    private func row(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.rowMeta).foregroundStyle(Palette.ink)
            Spacer()
            Text(value).font(Typography.amount).foregroundStyle(color).moneyLine()
        }
        .accessibilityElement(children: .combine)
    }
}

/// What each card owes now; the total is the server's.
private struct OwedCard: View {
    let netWorth: NetWorth
    let cards: [NetWorthCard]

    var body: some View {
        Card {
            SectionHeader(title: "Owed on cards", trailing: netWorth.owedText)
            if cards.isEmpty {
                Text("Nothing owed on your cards.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(cards) { card in
                if card.id != cards.first?.id { Divider().overlay(Palette.border) }
                AdaptiveRow(alignment: .center) {
                    HStack(spacing: 10) {
                        BankLogo(bankCode: card.bankCode, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                            Text(card.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                    }
                } trailing: {
                    Text(card.owedText).font(card.isKnown ? Typography.amount : Typography.rowMeta)
                        .foregroundStyle(card.isKnown ? Palette.ink : Palette.muted).moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// This month's flows as the server totals them, and its net; opens the Cash flow tab.
private struct ThisMonthCard: View {
    let month: CashFlowMonth
    let title: String
    let open: () -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Cash flow", trailing: title)
            if month.isEmpty {
                Text(CashFlow.emptyMessage(month.month)).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(month.groups.filter { $0.kind != .moves }) { group in
                ForEach(group.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(line.amountText).font(Typography.amount).moneyLine()
                            .foregroundStyle(group.kind.tone == .positive ? Palette.positive : Palette.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let net = month.netText {
                Divider().overlay(Palette.border)
                HStack(alignment: .firstTextBaseline) {
                    Text("Net").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Spacer()
                    if month.isPartial { Chip(label: CashFlow.partialLabel) }
                    Text(net).font(Typography.amount).foregroundStyle(month.netTone.color).moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
            LinkRow(title: "See cash flow", action: open)
        }
    }
}

/// The bank-account insights, each leading to its account (or Cash flow); owners dismiss one.
private struct WealthInsightsCard: View {
    let insights: [Insight]
    let profileCode: String
    let canEdit: Bool
    let dismiss: (Insight) -> Void
    @Environment(AccountLedgers.self) private var ledgers
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Card {
            SectionHeader(title: "Worth a look")
            ForEach(insights) { insight in
                if insight.id != insights.first?.id { Divider().overlay(Palette.border) }
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(insight.tone.color).frame(width: 3)
                        .accessibilityLabel(insight.severityLabel)
                    target(insight) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(insight.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                            Text(insight.body).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                            if let label = insight.wealthTarget?.label {
                                Text(label + " →").font(Typography.caption).foregroundStyle(Palette.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    if canEdit {
                        Button { dismiss(insight) } label: {
                            Image(systemName: "xmark").font(.caption)
                                .frame(minWidth: Metrics.tapMin, minHeight: Metrics.tapMin)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.muted)
                        .accessibilityLabel("Dismiss: \(insight.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func target<Label: View>(_ insight: Insight, @ViewBuilder label: () -> Label) -> some View {
        switch insight.wealthTarget {
        case .account(let code)?:
            NavigationLink {
                AccountLedgerView(model: ledgers.model(for: code), profileCode: profileCode, canEdit: canEdit)
            } label: { label() }
                .buttonStyle(.plain)
        case .cashFlow?:
            Button { tabs?.show(.cashFlow) } label: { label() }.buttonStyle(.plain)
        case nil:
            label()
        }
    }
}

/// `Manage accounts →`: a card's way to the tab that does more.
private struct LinkRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right").font(.caption2.weight(.semibold))
            }
            .font(Typography.rowMeta).foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity, minHeight: Metrics.tapMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
