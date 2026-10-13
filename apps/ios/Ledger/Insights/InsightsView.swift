import Charts
import LedgerKit
import SwiftUI

struct InsightsView: View {
    @Bindable var model: InsightsModel
    let month: MonthSelection
    let profileCode: String
    /// Switches to the Budgets tab.
    let showBudgets: () -> Void

    var body: some View {
        Page {
            MonthSwitcher(month: month).padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Picker("Period", selection: $model.period) {
                    ForEach(InsightsModel.Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(InsightsModel.periodCaption(model.period, month: month.requestMonth))
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
            TrendsLink(profileCode: profileCode)

            StateContainer(state: model.state, retry: reload) { content in
                let range = InsightsModel.range(for: model.period, month: month.requestMonth)
                SpendSplitCard(trend: content.trend, from: range.from, to: range.to, profileCode: profileCode)
                if !content.budgets.isEmpty {
                    BudgetsCard(budgets: content.budgets, scope: model.budgetsScope(), isCurrentMonth: month.isCurrent,
                                seeAll: showBudgets)
                }
                CategoriesCard(categories: content.categories, from: range.from, to: range.to, profileCode: profileCode)
                MerchantsCard(merchants: content.merchants, from: range.from, to: range.to)
                RecurringCard(recurring: content.activeRecurring, annualTotal: content.recurringAnnualTotal)
            }
        }
        .ledgerNavigation("Insights")
        .task(id: Key(period: model.period, month: month.requestMonth)) {
            await model.loadIfNeeded(profileCode: profileCode, month: month.requestMonth)
        }
        .refreshable { await model.load(profileCode: profileCode, month: month.requestMonth) }
    }

    private struct Key: Hashable {
        let period: InsightsModel.Period
        let month: CalendarDay?
    }

    private func reload() { Task { await model.load(profileCode: profileCode, month: month.requestMonth) } }
}

/// Each category's spend for the period; a row opens its drill-down (PAR-5).
private struct CategoriesCard: View {
    let categories: [CategorySpend]
    let from: CalendarDay
    let to: CalendarDay
    let profileCode: String

    var body: some View {
        Card {
            SectionHeader(title: "Categories")
            if categories.isEmpty {
                Text("Nothing categorised yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(categories) { category in
                NavigationLink {
                    CategoryDetailView(request: CategoryDrillDownRequest(target: CategoryTarget(category), from: from, to: to),
                                       profileCode: profileCode)
                } label: {
                    row(category)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ category: CategorySpend) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CategoryDot(token: category.colorToken)
                    Text(category.name).font(Typography.rowTitle)
                    Spacer()
                    Text(MoneyFormat.aed(category.amount, fractionDigits: 0)).font(Typography.amount)
                }
                ProgressView(value: category.shareFraction)
                    .tint(ChartPalette.color(for: category.colorToken))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(category.detailLabel)
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 4)
                    // vs the previous period of the same length (server `change`), "New" without one.
                    Chip(label: category.changeChip.label, tone: category.changeChip.tone)
                        .accessibilityLabel(category.changeAccessibilityLabel)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.subtle)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(category.name)")
    }
}

/// The merchant leaderboard; a row opens Activity on that merchant in the range (PAR-4).
private struct MerchantsCard: View {
    let merchants: [MerchantSpend]
    let from: CalendarDay
    let to: CalendarDay
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        Card {
            SectionHeader(title: "Top merchants")
            if merchants.isEmpty {
                Text("No merchants in this period.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(Array(merchants.enumerated()), id: \.element.id) { index, merchant in
                if let query = merchant.activityQuery(from: from, to: to) {
                    Button { tabs?.openActivity(query) } label: { row(index, merchant) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows its transactions in Activity")
                } else {
                    row(index, merchant)
                }
            }
        }
    }

    private func row(_ index: Int, _ merchant: MerchantSpend) -> some View {
        HStack {
            Text("\(index + 1)").font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(merchant.merchantName).font(Typography.rowTitle).lineLimit(1)
                Text("\(merchant.txnCount)× · avg \(MoneyFormat.aed(merchant.avgAmount, fractionDigits: 0))")
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text(MoneyFormat.aed(merchant.amount, fractionDigits: 0)).font(Typography.amount)
        }
        .contentShape(Rectangle())
    }
}

private struct RecurringCard: View {
    let recurring: [RecurringCharge]
    let annualTotal: Decimal

    var body: some View {
        Card {
            SectionHeader(title: "Recurring",
                          trailing: recurring.isEmpty ? nil : "\(MoneyFormat.aed(annualTotal, fractionDigits: 0)) / yr")
            if recurring.isEmpty {
                Text("No subscriptions detected yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(recurring) { charge in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(charge.merchantName).font(Typography.rowTitle)
                        Text(charge.nextExpected.map { "\(charge.cadence.capitalized) · next \(LedgerDates.dayLabel($0))" }
                             ?? charge.cadence.capitalized)
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFormat.aed(charge.lastAmount)).font(Typography.amount)
                        if let change = charge.priceChangeLabel { Chip(label: change, tone: .warn) }
                    }
                }
            }
        }
    }
}

private struct BudgetsCard: View {
    let budgets: [BudgetStatus]
    let scope: String
    let isCurrentMonth: Bool
    let seeAll: () -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Budgets", trailing: scope)
            ForEach(budgets) { budget in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(budget.title).font(Typography.rowTitle)
                        Spacer()
                        Text(budget.progressLabel).font(Typography.rowMeta).monospacedDigit()
                    }
                    BudgetMeter(row: budget, phase: isCurrentMonth ? .current : .past)
                }
            }
            Button(action: seeAll) {
                Label("See all budgets", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle())
                    .font(Typography.rowMeta)
                    .frame(maxWidth: .infinity, minHeight: Metrics.tapMin, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
        }
    }
}

/// Title first, icon after: `See all budgets ›`.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption.weight(.semibold))
        }
    }
}
