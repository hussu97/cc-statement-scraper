import Charts
import LedgerKit
import SwiftUI

/// This year's months beside last year's (web Insights › Year over year, BACKLOG PAR-12). Pick
/// a year; tap a month for both figures and the change. Every figure is `yoy_compare`'s.
struct YearOverYearView: View {
    let profileCode: String
    @Environment(AnalysisScreens.self) private var screens
    @State private var loader: AnalysisLoader<Int, YearComparison>?
    @State private var year: Int?
    @State private var selectedMonth: Int?

    var body: some View {
        let shown = year ?? screens.currentYear
        Page {
            Picker("Year", selection: Binding(get: { shown }, set: { year = $0; selectedMonth = nil })) {
                ForEach(YearComparison.yearOptions(currentYear: screens.currentYear), id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Palette.accent)
            .padding(.top, 8)
            if let loader {
                StateContainer(state: loader.state, retry: { reload(shown) }) { comparison in
                    if comparison.isEmpty {
                        AnalysisEmptyCard(systemImage: "chart.bar.xaxis", title: comparison.emptyTitle,
                                          message: YearComparison.emptyBody)
                    } else {
                        ComparisonCard(comparison: comparison, selectedMonth: $selectedMonth)
                    }
                }
            } else {
                LoadingCard()
            }
        }
        .ledgerNavigation(YearComparison.eyebrow)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AnalysisTaskKey(profileCode: profileCode, request: shown)) {
            let l = loader ?? screens.yearOverYear()
            loader = l
            await l.loadIfNeeded(profileCode: profileCode, request: shown)
        }
        .refreshable { await loader?.load(profileCode: profileCode, request: shown) }
    }

    private func reload(_ year: Int) {
        guard let loader else { return }
        Task { await loader.load(profileCode: profileCode, request: year) }
    }
}

private struct ComparisonCard: View {
    let comparison: YearComparison
    @Binding var selectedMonth: Int?

    private struct Bar: Identifiable {
        var id: String { "\(month)-\(series)" }
        let month: String
        let series: String
        let value: Double
    }

    private var bars: [Bar] {
        comparison.months.flatMap { m in
            [Bar(month: m.label, series: comparison.lastYearLabel, value: m.lastYear.chartValue),
             Bar(month: m.label, series: comparison.thisYearLabel, value: m.thisYear.chartValue)]
        }
    }

    var body: some View {
        Card {
            SectionHeader(title: comparison.title)
            if let readout = comparison.readout(month: selectedMonth) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(readout.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        if let change = readout.change { Chip(label: change.label, tone: change.tone) }
                    }
                    Text(readout.thisYear).font(Typography.amount).moneyLine()
                    Text(readout.lastYear).font(Typography.rowMeta).foregroundStyle(Palette.muted).moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
            chart
            HStack(spacing: 16) {
                legend(comparison.thisYearLabel, Palette.accent)
                legend(comparison.lastYearLabel, ChartPalette.uncategorized)
            }
            .accessibilityHidden(true)
        }
    }

    private var chart: some View {
        let labels = comparison.months.map(\.label)
        let selected = selectedMonth.flatMap { m in comparison.months.first { $0.month == m }?.label }
        return Chart(bars) { bar in
            BarMark(x: .value("Month", bar.month), y: .value("AED", bar.value))
                .foregroundStyle(by: .value("Year", bar.series))
                .position(by: .value("Year", bar.series))
                .opacity(selected == nil || selected == bar.month ? 1 : 0.45)
                .cornerRadius(2)
        }
        .chartForegroundStyleScale([comparison.thisYearLabel: Palette.accent,
                                    comparison.lastYearLabel: ChartPalette.uncategorized])
        .chartLegend(.hidden)
        .chartXScale(domain: labels)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) { Text(String(label.prefix(1))) }
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
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        if let label: String = proxy.value(atX: x) {
                            selectedMonth = comparison.months.first { $0.label == label }?.month
                        }
                    }
            }
        }
        .frame(height: 220)
        .chartAccessibility(comparison.accessibility)
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(Typography.caption).foregroundStyle(Palette.ink2)
        }
    }
}
