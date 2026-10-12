import Charts
import LedgerKit
import SwiftUI

struct OverviewView: View {
    let model: OverviewModel
    let month: MonthSelection
    let review: ReviewModel
    let profileCode: String
    let canResolve: Bool

    var body: some View {
        Page {
            MonthSwitcher(month: month).padding(.top, 8)
            StateContainer(state: model.state, retry: reload) { content in
                let overview = content.overview
                HeroCard(overview: overview)
                if overview.showsLiveSections(), let pending = overview.pendingSummary {
                    PendingStrip(summary: pending, lastSMS: overview.lastSMSLabel())
                }
                if !overview.attention().isEmpty {
                    AttentionCard(items: overview.attention(), review: review, profileCode: profileCode,
                                  canResolve: canResolve)
                }
                CategoryRingCard(categories: overview.ringCategories, total: overview.spend,
                                 scope: overview.scopeLabel(), emptyMessage: overview.emptyCategoriesMessage())
                AccountsCard(accounts: content.accounts, owedNow: content.overview.owedNowText,
                             owedNowCaveat: content.overview.owedNowCaveat)
                if !content.insights.isEmpty {
                    // Dismissing is an owner write (`insights_owner_dismiss`).
                    InsightsCard(insights: content.insights, dismiss: canResolve ? { insight in
                        Task { await model.dismiss(insight, profileCode: profileCode) }
                    } : nil)
                }
                if overview.showsLiveSections() { RecentCard(recent: overview.recent) }
            }
        }
        .ledgerNavigation("Overview")
        .task(id: month.requestMonth) { await model.loadIfNeeded(profileCode: profileCode, month: month.requestMonth) }
        .refreshable { await model.load(profileCode: profileCode, month: month.requestMonth) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode, month: month.requestMonth) } }
}

private struct HeroCard: View {
    let overview: Overview
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = Typography.heroBaseSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(overview.heroEyebrow().uppercased())
                .font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
            // Side by side while it fits; the unit goes above the number at
            // large sizes rather than the number shrinking below the unit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { unit; amount }
                VStack(alignment: .leading, spacing: 0) { unit; amount }
            }
            .accessibilityElement(children: .combine)
            if let comparison = overview.comparison() {
                Chip(label: comparison.text, tone: comparison.tone)
            }
            ForEach(overview.referenceLines, id: \.self) { line in
                Text(line).font(Typography.rowMeta).foregroundStyle(Palette.muted).monospacedDigit()
            }
        }
        .padding(.top, 8)
    }

    private var unit: some View {
        Text("AED").font(Typography.heroUnit).foregroundStyle(Palette.muted)
    }

    private var amount: some View {
        Text(overview.heroAmount).font(Typography.hero(size: heroSize)).foregroundStyle(Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.4)
    }
}

private struct PendingStrip: View {
    let summary: String
    let lastSMS: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                dot
                summaryText
                Spacer()
                if let lastSMS { lastText(lastSMS) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { dot; summaryText }
                if let lastSMS { lastText(lastSMS) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
    }

    private var dot: some View { Circle().fill(Palette.warn).frame(width: 8, height: 8) }
    private var summaryText: some View {
        Text(summary).font(Typography.rowTitle).monospacedDigit().foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func lastText(_ text: String) -> some View {
        Text(text).font(Typography.caption).foregroundStyle(Palette.muted)
    }
}

/// Open reviews and uncategorised spend; reviews open the Review screen.
private struct AttentionCard: View {
    let items: [AttentionItem]
    let review: ReviewModel
    let profileCode: String
    let canResolve: Bool

    var body: some View {
        Card {
            SectionHeader(title: "Needs attention")
            ForEach(items) { item in
                if item.kind == .reviews {
                    NavigationLink {
                        ReviewView(model: review, profileCode: profileCode, canResolve: canResolve)
                    } label: {
                        row(item, systemImage: "exclamationmark.bubble")
                    }
                    .buttonStyle(.plain)
                } else {
                    row(item, systemImage: "tag")
                }
            }
        }
    }

    private func row(_ item: AttentionItem, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Palette.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Text(item.detail).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if item.kind == .reviews {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct CategoryRingCard: View {
    let categories: [Overview.TopCategory]
    let total: Decimal
    let scope: String
    let emptyMessage: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Card {
            SectionHeader(title: "Where it went", trailing: scope)
            if categories.isEmpty {
                Text(emptyMessage).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else if typeSize.prefersStackedRows {
                VStack(alignment: .leading, spacing: 16) {
                    ring.frame(maxWidth: .infinity)
                    legend
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ring
                    legend
                }
            }
        }
    }

    private var ring: some View {
        Chart(categories) { category in
            SectorMark(angle: .value("Amount", category.amount.chartValue),
                       innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(ChartPalette.color(for: category.colorToken))
        }
        .frame(width: 128, height: 128)
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(MoneyFormat.compact(total)).font(Typography.amountLarge).moneyLine()
                Text("AED").font(Typography.caption).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 22)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .chartAccessibility(.categoryRing(categories, total: total))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(categories) { category in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CategoryDot(token: category.colorToken)
                    Text(category.displayName).font(Typography.rowMeta)
                        .lineLimit(typeSize.prefersStackedRows ? 2 : 1)
                    Spacer(minLength: 4)
                    Text(MoneyFormat.compact(category.amount)).font(Typography.rowMeta).moneyLine()
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

private struct AccountsCard: View {
    let accounts: [AccountSummary]
    let owedNow: String?
    let owedNowCaveat: String?

    var body: some View {
        Card {
            SectionHeader(title: "Cards")
            if let owedNow, !accounts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Owed now").font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(owedNow).font(Typography.amount).moneyLine()
                    }
                    if let owedNowCaveat {
                        Text(owedNowCaveat).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                Divider().overlay(Palette.border)
            }
            if accounts.isEmpty {
                Text("Cards appear after the first statement or SMS.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(accounts) { summary in
                VStack(alignment: .leading, spacing: 6) {
                    AdaptiveRow(alignment: .firstTextBaseline) {
                        HStack(alignment: .center, spacing: 10) {
                            BankLogo(bankCode: summary.account.bankCode, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.account.title).font(Typography.rowTitle)
                                if let cards = summary.account.cardsLabel {
                                    Text(cards).font(Typography.caption).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } trailing: {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let balance = summary.account.latestStatement?.closingBalance {
                                Text(MoneyFormat.aed(balance)).font(Typography.amount).moneyLine()
                            }
                            if let due = summary.due() {
                                Text(due.text).font(Typography.caption).foregroundStyle(due.tone.color)
                            }
                        }
                    }
                    if let owed = summary.owedNowText {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Owed now").font(Typography.caption).foregroundStyle(Palette.muted)
                            Spacer()
                            Text(owed).font(Typography.rowTitle).moneyLine()
                        }
                        .accessibilityElement(children: .combine)
                        if let note = summary.owedNowNote() {
                            Text(note).font(Typography.caption).foregroundStyle(Palette.muted)
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
    /// Nil when the user may not dismiss (not an owner).
    let dismiss: ((Insight) -> Void)?

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
                    if let dismiss {
                        Button { dismiss(insight) } label: {
                            Image(systemName: "xmark").font(.caption).frame(minWidth: 44, minHeight: 44)
                        }
                        .foregroundStyle(Palette.muted)
                        .accessibilityLabel("Dismiss insight")
                    }
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
                .accessibilityElement(children: .combine)
            }
        }
    }
}
