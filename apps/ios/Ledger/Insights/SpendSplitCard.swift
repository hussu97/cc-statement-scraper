import Charts
import LedgerKit
import SwiftUI

/// Insights' Monthly spend: plain bars (`spend_series`) or stacked by
/// category, bank or merchant (`spend_breakdown`, top 10 + Others), with a
/// legend, a selection callout and each group's total and share for the range.
struct SpendSplitCard: View {
    let trend: [SpendPoint]
    let from: CalendarDay
    let to: CalendarDay
    let profileCode: String
    @Environment(SpendSplitModel.self) private var split
    @State private var showsFilter = false

    var body: some View {
        @Bindable var split = split
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Monthly spend")
                FilterButton(count: split.filter.activeCount) { showsFilter = true }
            }
            if let summary = split.filterSummary {
                FilterSummary(text: summary, clear: split.clearFilter)
            }
            Picker("Split by", selection: $split.grouping) {
                ForEach(SpendSplitGrouping.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if split.grouping == .none {
                TrendBody(state: split.trend(unfiltered: trend), empty: split.emptyMessage,
                          retry: { Task { await load(force: true) } })
            } else {
                BreakdownBody(split: split, retry: { Task { await load(force: true) } })
            }
        }
        .task(id: Key(grouping: split.grouping, filter: split.filter, from: from, to: to, profile: profileCode)) {
            await load(force: false)
        }
        .sheet(isPresented: $showsFilter) {
            SpendFilterSheet(initial: split.filter, options: split.options) { split.filter = $0 }
                .task { await split.loadOptions(profileCode: profileCode) }
        }
    }

    private struct Key: Hashable {
        let grouping: SpendSplitGrouping
        let filter: SpendFilter
        let from: CalendarDay
        let to: CalendarDay
        let profile: String
    }

    private func load(force: Bool) async {
        await split.load(profileCode: profileCode, from: from, to: to, force: force)
    }
}

/// The filter button, with how many filters are on.
private struct FilterButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(count > 0 ? "Filter · \(count)" : "Filter")
            }
            .font(Typography.caption)
        }
        .buttonStyle(.borderless)
        .tint(Palette.accent)
        .accessibilityLabel(count > 0 ? "Filter, \(count) on" : "Filter")
    }
}

/// What the chart is filtered to, and a way back to all spend.
private struct FilterSummary: View {
    let text: String
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(Typography.caption).foregroundStyle(Palette.ink2).lineLimit(2)
            Spacer(minLength: 4)
            Button("Clear", action: clear).font(Typography.caption).buttonStyle(.borderless).tint(Palette.accent)
                .accessibilityLabel("Clear filters")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusSm))
        .accessibilityElement(children: .combine)
    }
}

/// The unsplit bars: the screen's trend, or the filtered one with its own states.
private struct TrendBody: View {
    let state: LoadState<[SpendPoint]>
    let empty: String
    let retry: () -> Void

    var body: some View {
        if let points = state.value {
            TrendBars(points: points, empty: empty).opacity(state.isLoading ? 0.5 : 1)
        } else if let error = state.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                Button("Try again", action: retry).buttonStyle(.bordered).tint(Palette.accent)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            .frame(height: 180)
        }
    }
}

private struct TrendBars: View {
    let points: [SpendPoint]
    let empty: String

    var body: some View {
        if points.isEmpty {
            Text(empty).font(Typography.rowMeta).foregroundStyle(Palette.muted)
        } else {
            Chart(points) { point in
                BarMark(x: .value("Month", point.monthLabel), y: .value("AED", point.amount.chartValue))
                    .foregroundStyle(Palette.accent)
                    .cornerRadius(3)
            }
            .chartYAxis { aedAxis }
            .frame(height: 180)
            .chartAccessibility(.monthlyTrend(points))
        }
    }
}

private struct BreakdownBody: View {
    @Bindable var split: SpendSplitModel
    let retry: () -> Void

    var body: some View {
        if let b = split.state.value {
            if b.isEmpty {
                Text(split.emptyMessage).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else {
                if let callout = split.callout { CalloutBox(callout: callout) }
                StackedChart(breakdown: b, selected: $split.selectedMonth)
                    .opacity(split.state.isLoading ? 0.5 : 1)
                Legend(breakdown: b)
                GroupList(breakdown: b)
            }
        } else if let error = split.state.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                Button("Try again", action: retry).buttonStyle(.bordered).tint(Palette.accent)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            .frame(height: 180)
        }
    }
}

private struct StackedChart: View {
    let breakdown: SpendBreakdown
    @Binding var selected: String?

    var body: some View {
        Chart {
            ForEach(breakdown.segments) { seg in
                BarMark(x: .value("Month", seg.monthLabel), y: .value("AED", seg.amount.chartValue))
                    .foregroundStyle(by: .value("Group", seg.groupKey))
            }
            if let selected {
                RuleMark(x: .value("Month", selected))
                    .foregroundStyle(Palette.borderStrong.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 16))
                    .zIndex(-1)
            }
        }
        .chartForegroundStyleScale(domain: breakdown.groups.map(\.key),
                                   range: breakdown.groups.map { splitColor(breakdown.colorToken(for: $0)) })
        .chartXScale(domain: breakdown.monthLabels)
        .chartLegend(.hidden)
        .chartYAxis { aedAxis }
        .chartOverlay { proxy in
            // Tap a month to pin its callout; tap it again to clear.
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        guard let month: String = proxy.value(atX: x) else { return }
                        selected = selected == month ? nil : month
                    }
            }
        }
        .frame(height: 200)
        .chartAccessibility(.breakdown(breakdown, grouping: SpendSplitGrouping(rawValue: breakdown.groupBy) ?? .category))
    }
}

/// The selected month: total, then each group's AED and share of the month.
private struct CalloutBox: View {
    let callout: SpendCallout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(callout.title).font(Typography.rowTitle)
                Spacer()
                Text(callout.total).font(Typography.amount).moneyLine()
            }
            if callout.rows.isEmpty {
                Text("No spending this month.").font(Typography.caption).foregroundStyle(Palette.muted)
            }
            ForEach(callout.rows) { row in
                HStack(spacing: 8) {
                    SplitDot(token: row.colorToken)
                    Text(row.label).font(Typography.caption).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(row.amount).font(Typography.caption).monospacedDigit()
                    if let share = row.share {
                        Text(share).font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        .accessibilityElement(children: .contain)
    }
}

private struct Legend: View {
    let breakdown: SpendBreakdown

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(breakdown.groups) { group in
                HStack(spacing: 6) {
                    SplitDot(token: breakdown.colorToken(for: group))
                    Text(group.label).font(Typography.caption).foregroundStyle(Palette.ink2).lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)   // the list below says the same, with figures
    }
}

/// Each group's total and share over the whole range.
private struct GroupList: View {
    let breakdown: SpendBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Palette.border)
            ForEach(breakdown.groups) { group in
                HStack(spacing: 10) {
                    if breakdown.showsBankLogos && !group.isOther {
                        BankLogo(bankCode: group.key, size: 20)
                    } else {
                        SplitDot(token: breakdown.colorToken(for: group), size: 10).frame(width: 20)
                    }
                    Text(group.label).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(MoneyFormat.aed(group.total, fractionDigits: 0)).font(Typography.rowMeta).moneyLine()
                    Text(SpendBreakdown.shareLabel(group.share)).font(Typography.caption).monospacedDigit()
                        .foregroundStyle(Palette.muted).frame(minWidth: 40, alignment: .trailing)
                }
                .overlay(alignment: .leading) {
                    if breakdown.showsBankLogos && !group.isOther {
                        // The colour that bank has in the chart.
                        Circle().fill(splitColor(breakdown.colorToken(for: group)))
                            .frame(width: 6, height: 6).offset(x: 17, y: 8)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

@AxisContentBuilder private var aedAxis: some AxisContent {
    AxisMarks { value in
        AxisGridLine().foregroundStyle(ChartPalette.grid)
        AxisValueLabel {
            if let v = value.as(Double.self) { Text(MoneyFormat.compact(Decimal(Int(v)))) }
        }
    }
}

/// The chart palette, with Others in its own neutral (Uncategorized keeps the grey).
private func splitColor(_ token: String?) -> Color {
    token == SpendBreakdown.otherToken ? Palette.borderStrong : ChartPalette.color(for: token)
}

private struct SplitDot: View {
    let token: String?
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(splitColor(token)).frame(width: size, height: size)
    }
}
