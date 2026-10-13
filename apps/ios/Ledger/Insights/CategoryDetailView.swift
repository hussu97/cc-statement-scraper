import Charts
import LedgerKit
import SwiftUI

/// One category over a range (BACKLOG PAR-5, web `/insights/category/$code`): what it cost and
/// how that compares with the previous period, its months, and its top merchants. Every figure
/// is the server's; `CategoryDrillDownModel` (LedgerKit) loads and words them.
struct CategoryDetailView: View {
    let request: CategoryDrillDownRequest
    let profileCode: String
    @Environment(CategoryDrillDowns.self) private var drillDowns
    @Environment(TabRouter.self) private var tabs: TabRouter?
    @State private var model: CategoryDrillDownModel?

    var body: some View {
        Page {
            HStack(spacing: 8) {
                CategoryDot(token: request.target.colorToken, size: 10)
                Text(request.rangeLabel()).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)
            if let model {
                StateContainer(state: model.state, retry: reload) { detail in
                    SummaryCard(row: detail.row, range: request.rangeLabel())
                    if let tabs {
                        Button { tabs.openActivity(request.activityQuery) } label: {
                            Label("See transactions", systemImage: "list.bullet")
                                .font(Typography.body)
                                .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                        .accessibilityHint("Shows this category's transactions in Activity")
                    }
                    TrendCard(detail: detail, model: model)
                    MerchantsCard(detail: detail)
                }
            } else {
                LoadingCard()
            }
        }
        .ledgerNavigation(request.target.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: request) {
            let m = model ?? drillDowns.makeModel()
            model = m
            await m.loadIfNeeded(profileCode: profileCode, request: request)
        }
        .refreshable { await model?.load(profileCode: profileCode, request: request) }
    }

    private func reload() {
        guard let model else { return }
        Task { await model.load(profileCode: profileCode, request: request) }
    }
}

/// Spent, the change against the previous period, share of all spend and transactions.
private struct SummaryCard: View {
    let row: CategorySpend?
    let range: String

    var body: some View {
        Card {
            if let row {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent").font(Typography.caption).foregroundStyle(Palette.muted)
                    Text(MoneyFormat.aed(row.amount)).font(Typography.amountLarge).moneyLine()
                }
                .accessibilityElement(children: .combine)
                Divider().overlay(Palette.border)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("vs previous period").font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Chip(label: row.changeChip.label, tone: row.changeChip.tone)
                    Text(row.previousLabel).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                stat("Share of spending", row.shareLabel)
                stat("Transactions", row.transactionsLabel)
            } else {
                Label("No spending in this range", systemImage: "chart.bar").font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                Text("Nothing was spent in this category between \(range). Pick a longer period to see its history.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).font(Typography.rowTitle).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The category's monthly totals over at least six months; tap a month for its figure.
private struct TrendCard: View {
    let detail: CategoryDrillDown
    @Bindable var model: CategoryDrillDownModel

    private var color: Color { ChartPalette.color(for: detail.request.target.colorToken) }

    var body: some View {
        Card {
            SectionHeader(title: "Month by month", trailing: detail.request.trendRangeLabel())
            let bars = detail.bars
            if bars.isEmpty {
                Text("No spending in these months.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else {
                if let readout = model.readout {
                    HStack(alignment: .firstTextBaseline) {
                        Text(readout.title).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        Spacer()
                        Text(readout.amountLabel).font(Typography.amount).moneyLine()
                    }
                    .accessibilityHidden(true)   // the chart's descriptor reads every month
                }
                chart(bars)
            }
        }
    }

    private func chart(_ bars: [CategoryDrillDown.Bar]) -> some View {
        let selected = model.readout?.label
        return Chart(bars) { bar in
            BarMark(x: .value("Month", bar.label), y: .value("AED", bar.amount.chartValue))
                .foregroundStyle(color.opacity(bar.label == selected ? 1 : 0.45))
                .cornerRadius(3)
        }
        .chartXScale(domain: bars.map(\.label))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(MoneyFormat.compact(Decimal(Int(v)))) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        if let month: String = proxy.value(atX: x) { model.selectedMonth = month }
                    }
            }
        }
        .frame(height: 180)
        .chartAccessibility(.categoryTrend(detail))
    }
}

/// The top merchants in the range, the rest folded into Others by the server.
private struct MerchantsCard: View {
    let detail: CategoryDrillDown

    private var color: Color { ChartPalette.color(for: detail.request.target.colorToken) }

    var body: some View {
        Card {
            SectionHeader(title: "Top merchants", trailing: detail.request.rangeLabel())
            let rows = detail.merchantRows
            if rows.isEmpty {
                Text("No merchants in this range. Purchases in this category appear here.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(Typography.rowTitle).lineLimit(2)
                            .foregroundStyle(row.isBucket ? Palette.muted : Palette.ink)
                        Spacer(minLength: 8)
                        Text(row.amountLabel).font(Typography.amount).moneyLine()
                    }
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.surface3)
                                Capsule().fill(color).frame(width: geo.size.width * row.barFraction)
                            }
                        }
                        .frame(height: 4)
                        Text(row.shareLabel).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
