import Charts
import LedgerKit
import SwiftUI

/// The broker account's value per day against its net deposits (at Zerodha, the holdings against their cost). Days rebuilt from the broker's
/// performance index are dashed and lighter; the synced ones solid. Every point is the server's.
struct BrokerValueChartCard: View {
    let chart: BrokerValueChart

    var body: some View {
        Card {
            SectionHeader(title: "Value over time")
            if chart.showsChart {
                legend
                plot
            }
            Text(chart.note).font(Typography.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            LegendKey(label: BrokerValueChart.valueLabel, color: Palette.accent, dashed: false)
            if chart.hasEstimated {
                LegendKey(label: BrokerValueChart.estimatedLabel, color: Palette.accent.opacity(0.55), dashed: true)
            }
            LegendKey(label: chart.lineLabel, color: Palette.muted, dashed: false)
        }
        .accessibilityHidden(true)
    }

    private var plot: some View {
        Chart {
            ForEach(chart.deposits) { p in
                LineMark(x: .value("Day", p.day.startDate, unit: .day), y: .value("Amount", p.value.chartValue),
                         series: .value("Line", "deposits"))
                    .foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(chart.values) { p in
                LineMark(x: .value("Day", p.day.startDate, unit: .day), y: .value("Amount", p.value.chartValue),
                         series: .value("Line", p.run))
                    .foregroundStyle(p.estimated ? Palette.accent.opacity(0.55) : Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: p.estimated ? [5, 3] : []))
                    .interpolationMethod(.linear)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(BrokerValueChart.axisLabel(CalendarDay(date: date))) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(InvestmentsChart.axisLabel(v)) }
                }
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Value over time against \(chart.lineLabel.lowercased())")
        .accessibilityValue(chart.accessibilityValue)
    }
}

/// A legend swatch: a short line, solid or dashed, and its label.
private struct LegendKey: View {
    let label: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 16, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 16, height: 8)
            Text(label).font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }
}
