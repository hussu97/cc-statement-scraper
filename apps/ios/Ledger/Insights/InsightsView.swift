import Charts
import LedgerKit
import SwiftUI

struct InsightsView: View {
    @Bindable var model: InsightsModel
    let month: MonthSelection
    let profileCode: String

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

            StateContainer(state: model.state, retry: reload) { content in
                let range = InsightsModel.range(for: model.period, month: month.requestMonth)
                SpendSplitCard(trend: content.trend, from: range.from, to: range.to, profileCode: profileCode)
                if !content.budgets.isEmpty { BudgetsCard(budgets: content.budgets, scope: model.budgetsScope()) }
                CategoriesCard(categories: content.categories)
                MerchantsCard(merchants: content.merchants)
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

private struct CategoriesCard: View {
    let categories: [CategorySpend]

    var body: some View {
        Card {
            SectionHeader(title: "Categories")
            if categories.isEmpty {
                Text("Nothing categorised yet.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(categories.prefix(10)) { category in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        CategoryDot(token: category.colorToken)
                        Text(category.name).font(Typography.rowTitle)
                        Spacer()
                        Text(MoneyFormat.aed(category.amount, fractionDigits: 0)).font(Typography.amount)
                    }
                    ProgressView(value: category.shareFraction)
                        .tint(ChartPalette.color(for: category.colorToken))
                    Text(category.detailLabel)
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

private struct MerchantsCard: View {
    let merchants: [MerchantSpend]

    var body: some View {
        Card {
            SectionHeader(title: "Top merchants")
            if merchants.isEmpty {
                Text("No merchants in this period.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(Array(merchants.enumerated()), id: \.element.id) { index, merchant in
                HStack {
                    Text("\(index + 1)").font(Typography.caption).monospacedDigit().foregroundStyle(Palette.subtle)
                        .frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(merchant.merchantName).font(Typography.rowTitle).lineLimit(1)
                        Text("\(merchant.txnCount)× · avg \(MoneyFormat.aed(merchant.avgAmount, fractionDigits: 0))")
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Text(MoneyFormat.aed(merchant.amount, fractionDigits: 0)).font(Typography.amount)
                }
            }
        }
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
                    ProgressView(value: budget.progressFraction).tint(budget.tone.color)
                }
            }
        }
    }
}
