import Charts
import LedgerKit
import SwiftUI

struct OverviewView: View {
    let model: OverviewModel
    let month: MonthSelection
    let review: ReviewModel
    let profileCode: String
    let canResolve: Bool
    /// SMS stuck on this phone for over an hour, nil when none.
    let outboxAlert: StaleOutboxAlert?
    let openSettings: () -> Void
    /// The empty-ledger checklist's links: the SMS guide and Statements.
    let settings: SettingsModel
    let statements: StatementsModel
    /// Cash & accounts, opened from the cash tile (Phase 2d).
    let cash: CashModel
    /// Links into Activity (PAR-4).
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Page {
            MonthSwitcher(month: month).padding(.top, 8)
            if let outboxAlert { OutboxStrip(alert: outboxAlert, open: openSettings) }
            StateContainer(state: model.state, retry: reload) { content in
                let overview = content.overview
                // An empty ledger: first steps instead of "AED 0" and empty cards (IOS-23).
                if let setup = content.setup {
                    SetupChecklistCard(checklist: setup, settings: settings, statements: statements,
                                       profileCode: profileCode, canWrite: canResolve)
                } else {
                    HeroCard(overview: overview)
                }
                if overview.showsLiveSections(), let lastAlert = overview.lastCardAlertLabel() {
                    Text(lastAlert).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                if content.showsCashTile, let position = content.cash {
                    CashTile(position: position, cash: cash, profileCode: profileCode, canEdit: canResolve)
                }
                if !overview.attention().isEmpty {
                    AttentionCard(items: overview.attention(), review: review, profileCode: profileCode,
                                  canResolve: canResolve) { tabs?.openActivity(overview.uncategorisedActivity) }
                }
                if content.setup == nil {
                    CategoryRingCard(overview: overview, profileCode: profileCode)
                    AccountsCard(accounts: content.accounts, owedNow: content.overview.owedNowText,
                                 owedNowCaveat: content.overview.owedNowCaveat)
                }
                if !content.insights.isEmpty {
                    // Dismissing is an owner write (`insights_owner_dismiss`).
                    InsightsCard(insights: content.insights, profileCode: profileCode, canDismiss: canResolve,
                                 dismiss: canResolve ? { insight in
                        Task { await model.dismiss(insight, profileCode: profileCode) }
                    } : nil)
                }
                if overview.showsLiveSections() && content.setup == nil {
                    RecentCard(recent: overview.recent) { tabs?.openTransaction($0.txnCode) }
                }
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
            // One VoiceOver element: "October spend so far, 860 dirhams".
            VStack(alignment: .leading, spacing: 10) {
                Text(overview.heroEyebrow().uppercased())
                    .font(Typography.caption).tracking(1.2).foregroundStyle(Palette.muted)
                // Side by side while it fits; the unit goes above the number at
                // large sizes rather than the number shrinking below the unit.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { unit; amount }
                    VStack(alignment: .leading, spacing: 0) { unit; amount }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(overview.heroAccessibilityLabel())
            if let comparison = overview.comparison() {
                Chip(label: comparison.text, tone: comparison.tone)
            }
            ForEach(overview.referenceLines, id: \.self) { line in
                Text(line).font(Typography.rowMeta).foregroundStyle(Palette.muted).monospacedDigit()
            }
            if let pace = overview.paceRule() { PaceRuleView(rule: pace) }
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

/// Open reviews and uncategorised spend; reviews open the Review screen, the
/// uncategorised count Activity on those transactions.
private struct AttentionCard: View {
    let items: [AttentionItem]
    let review: ReviewModel
    let profileCode: String
    let canResolve: Bool
    let openUncategorised: () -> Void

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
                    Button(action: openUncategorised) { row(item, systemImage: "tag") }
                        .buttonStyle(.plain)
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
        }
        .contentShape(Rectangle())
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

/// The first open insights, alerts first, each linking where it leads, and the whole feed (PAR-9).
private struct InsightsCard: View {
    let insights: [Insight]
    let profileCode: String
    let canDismiss: Bool
    /// Nil when the user may not dismiss (not an owner).
    let dismiss: ((Insight) -> Void)?
    @Environment(InsightFeedModel.self) private var feed: InsightFeedModel?

    var body: some View {
        Card {
            SectionHeader(title: "Worth a look")
            ForEach(InsightFeed.sorted(insights).prefix(4)) { insight in
                InsightRow(insight: insight, link: feed?.link(for: insight), host: .overview, profileCode: profileCode,
                           dismiss: dismiss.map { dismiss in { dismiss(insight) } })
            }
            if feed != nil {
                NavigationLink {
                    InsightFeedView(profileCode: profileCode, canDismiss: canDismiss, host: .overview)
                } label: {
                    Text("All insights").font(Typography.rowMeta).foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
