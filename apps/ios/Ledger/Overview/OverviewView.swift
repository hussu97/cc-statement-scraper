import Charts
import LedgerKit
import SwiftUI

struct OverviewView: View {
    let model: OverviewModel
    let profileCode: String

    var body: some View {
        Page {
            StateContainer(state: model.state, retry: reload) { content in
                HeroCard(overview: content.overview)
                if let pending = content.overview.pendingSummary {
                    PendingStrip(summary: pending, lastSMS: content.overview.lastSMSLabel())
                }
                CategoryRingCard(categories: content.overview.ringCategories, total: content.overview.spend)
                AccountsCard(accounts: content.accounts)
                if !content.insights.isEmpty {
                    InsightsCard(insights: content.insights) { insight in
                        Task { await model.dismiss(insight, profileCode: profileCode) }
                    }
                }
                RecentCard(recent: content.overview.recent)
            }
        }
        .ledgerNavigation("Overview")
        .refreshable { await model.load(profileCode: profileCode) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

private struct HeroCard: View {
    let overview: Overview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overview.monthTitle.uppercased())
                .font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
                Text(overview.heroAmount).font(Typography.hero).foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            let comparison = overview.comparison
            Chip(label: comparison.text, tone: comparison.tone)
            Text(overview.paceText).font(Typography.rowMeta).foregroundStyle(Palette.muted)
        }
        .padding(.top, 8)
    }
}

private struct PendingStrip: View {
    let summary: String
    let lastSMS: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.warn).frame(width: 8, height: 8)
            Text(summary).font(Typography.rowTitle).monospacedDigit().foregroundStyle(Palette.ink)
            Spacer()
            if let lastSMS { Text(lastSMS).font(Typography.caption).foregroundStyle(Palette.muted) }
        }
        .padding(12)
        .background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
    }
}

private struct CategoryRingCard: View {
    let categories: [Overview.TopCategory]
    let total: Decimal

    var body: some View {
        Card {
            SectionHeader(title: "Where it went", trailing: "This month")
            if categories.isEmpty {
                Text("No spending this month yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Chart(categories) { category in
                        SectorMark(angle: .value("Amount", category.amount.chartValue),
                                   innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(ChartPalette.color(for: category.colorToken))
                    }
                    .frame(width: 128, height: 128)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text(MoneyFormat.compact(total)).font(Typography.amountLarge)
                            Text("AED").font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(categories) { category in
                            HStack(spacing: 8) {
                                CategoryDot(token: category.colorToken)
                                Text(category.displayName).font(Typography.rowMeta).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(MoneyFormat.compact(category.amount)).font(Typography.rowMeta).monospacedDigit()
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AccountsCard: View {
    let accounts: [AccountSummary]

    var body: some View {
        Card {
            SectionHeader(title: "Cards")
            if accounts.isEmpty {
                Text("Cards appear after the first statement or SMS.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(accounts) { summary in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.account.title).font(Typography.rowTitle)
                            if let cards = summary.account.cardsLabel {
                                Text("\(summary.account.bankCode) \(cards)").font(Typography.caption).foregroundStyle(Palette.muted)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let balance = summary.account.latestStatement?.closingBalance {
                                Text(MoneyFormat.aed(balance)).font(Typography.amount)
                            }
                            if let due = summary.dueLabel() {
                                Text(due).font(Typography.caption).foregroundStyle(summary.dueTone().color)
                            }
                        }
                    }
                    if let used = summary.utilisationLabel {
                        ProgressView(value: summary.utilisationFraction)
                            .tint(summary.utilisationTone.color)
                        Text("\(used) · \(MoneyFormat.aed(summary.account.unbilledAed)) since statement")
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                if summary.id != accounts.last?.id { Divider().overlay(Palette.border) }
            }
        }
    }
}

private struct InsightsCard: View {
    let insights: [Insight]
    let dismiss: (Insight) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Worth a look")
            ForEach(insights.prefix(4)) { insight in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(insight.tone.color).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(Typography.rowTitle)
                        Text(insight.body).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button { dismiss(insight) } label: { Image(systemName: "xmark").font(.caption) }
                        .foregroundStyle(Palette.subtle)
                }
            }
        }
    }
}

private struct RecentCard: View {
    let recent: [Overview.RecentTransaction]

    var body: some View {
        Card {
            SectionHeader(title: "Latest")
            if recent.isEmpty {
                Text("No transactions yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(recent) { txn in
                HStack {
                    CategoryDot(token: txn.categoryColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txn.title).font(Typography.rowTitle).lineLimit(1)
                        Text(LedgerDates.relativeDayLabel(txn.txnDate)).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(txn.amountLabel).font(Typography.amount)
                            .foregroundStyle(txn.isCredit ? Palette.positive : Palette.ink)
                        Text(txn.badge.label).font(Typography.caption).foregroundStyle(Palette.subtle)
                    }
                }
            }
        }
    }
}
