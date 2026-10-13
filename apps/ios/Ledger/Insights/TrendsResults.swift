import Charts
import LedgerKit
import SwiftUI

/// Trends' chart and table: loading, failed and empty states, then the bars (stacked by group),
/// the legend and every bucket with spend. Every figure is the server's.
struct TrendsResults: View {
    @Bindable var model: TrendsModel
    let retry: () -> Void

    var body: some View {
        StateContainer(state: model.state, retry: retry) { series in
            if series.isEmpty {
                Card {
                    Text(model.emptyMessage).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    if !model.filter.isEmpty {
                        Button("Clear filters", action: model.clearFilter).buttonStyle(.bordered).tint(Palette.accent)
                    }
                }
            } else {
                TrendsChartCard(series: series, model: model)
                TrendsTable(series: series, model: model)
            }
        }
    }
}

private struct TrendsChartCard: View {
    let series: TrendsSeries
    @Bindable var model: TrendsModel

    var body: some View {
        Card {
            if let bucket = model.selected {
                TrendsCallout(series: series, bucket: bucket)
            }
            TrendsChart(series: series, selected: $model.selectedBucket)
                .opacity(model.state.isLoading ? 0.5 : 1)
            if series.isGrouped { TrendsLegend(series: series) }
        }
    }
}

private struct TrendsChart: View {
    let series: TrendsSeries
    @Binding var selected: String?

    var body: some View {
        Chart {
            if series.isGrouped {
                ForEach(series.segments) { entry in
                    BarMark(x: .value("Bucket", entry.bucket.iso), y: .value("AED", entry.amount.chartValue))
                        .foregroundStyle(by: .value("Group", entry.groupKey))
                        .opacity(dimmed(entry.bucket.iso) ? 0.35 : 1)
                }
            } else {
                ForEach(series.buckets.filter { $0.total != nil }) { bucket in
                    BarMark(x: .value("Bucket", bucket.id), y: .value("AED", (bucket.total ?? 0).chartValue))
                        .foregroundStyle(by: .value("Group", Self.totalKey))
                        .opacity(dimmed(bucket.id) ? 0.35 : 1)
                        .cornerRadius(2)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.isGrouped ? series.groups.map(\.key) : [Self.totalKey],
                                   range: series.isGrouped ? series.groups.map { trendColor($0.colorToken) } : [Palette.accent])
        .chartXScale(domain: series.buckets.map(\.id))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: series.axisBucketIDs(maxLabels: 6)) { value in
                AxisValueLabel {
                    if let id = value.as(String.self) { Text(series.bucket(id: id)?.label ?? "") }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(MoneyFormat.compact(Decimal(Int(v)))) }
                }
            }
        }
        .chartOverlay { proxy in
            // Tap a bar to select its bucket; tap it again to clear.
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        guard let id: String = proxy.value(atX: x) else { return }
                        selected = selected == id ? nil : id
                    }
            }
        }
        .frame(height: 220)
        .chartAccessibility(series.accessibility)
    }

    private static let totalKey = "__total__"

    private func dimmed(_ id: String) -> Bool { selected != nil && selected != id }
}

/// The selected bucket: its server total, and a way to its transactions.
private struct TrendsCallout: View {
    let series: TrendsSeries
    let bucket: TrendsSeries.Bucket
    @Environment(TabRouter.self) private var tabs: TabRouter?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.title).font(Typography.rowTitle)
                if let count = bucket.txnCount {
                    Text(TrendsSeries.countLabel(count)).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(bucket.total.map { MoneyFormat.aed($0, fractionDigits: 0) } ?? "No spending")
                    .font(Typography.amount).moneyLine()
                if let tabs, let query = series.activityQuery(bucket: bucket, group: nil) {
                    Button("See transactions") { tabs.openActivity(query) }
                        .font(Typography.caption).buttonStyle(.borderless).tint(Palette.accent)
                }
            }
        }
        .padding(10)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
    }
}

/// Each group's colour; Bank's also with the server's total and share for the range.
private struct TrendsLegend: View {
    let series: TrendsSeries

    var body: some View {
        if series.groups.contains(where: { $0.total != nil }) {
            VStack(alignment: .leading, spacing: 10) {
                Divider().overlay(Palette.border)
                ForEach(series.groups) { group in
                    HStack(spacing: 10) {
                        if series.group == .bank, let code = group.code {
                            BankLogo(bankCode: code, size: 20)
                        } else {
                            TrendDot(token: group.colorToken, size: 10).frame(width: 20)
                        }
                        Text(group.label).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
                        Spacer(minLength: 8)
                        if let total = group.total {
                            Text(MoneyFormat.aed(total, fractionDigits: 0)).font(Typography.rowMeta).moneyLine()
                        }
                        if let share = group.share {
                            Text(SpendBreakdown.shareLabel(share)).font(Typography.caption).monospacedDigit()
                                .foregroundStyle(Palette.muted).frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if series.group == .bank, group.code != nil {
                            // The colour that bank has in the chart.
                            TrendDot(token: group.colorToken, size: 6).offset(x: 17, y: 8)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(series.groups) { group in
                    HStack(spacing: 6) {
                        TrendDot(token: group.colorToken)
                        Text(group.label).font(Typography.caption).foregroundStyle(Palette.ink2).lineLimit(1)
                    }
                }
            }
            .accessibilityHidden(true)   // the table below says the same, with figures
        }
    }
}

/// The chart palette, with the folded rest in its own neutral (Uncategorised keeps the grey).
func trendColor(_ token: String?) -> Color {
    token == SpendBreakdown.otherToken ? Palette.borderStrong : ChartPalette.color(for: token)
}

struct TrendDot: View {
    let token: String?
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(trendColor(token)).frame(width: size, height: size)
    }
}
