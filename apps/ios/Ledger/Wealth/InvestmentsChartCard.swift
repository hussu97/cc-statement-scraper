import Charts
import LedgerKit
import SwiftUI

/// The last 90 days: the holdings' value against their cost, or (the segmented control) the 24K
/// gold or silver price per gram. Every point is the server's; a day without one is left out.
struct InvestmentsChartCard: View {
    let model: InvestmentsModel
    let content: InvestmentsModel.Content

    var body: some View {
        Card {
            SectionHeader(title: "Last \(InvestmentsChart.days) days")
            Picker("Chart", selection: Binding(get: { model.chart }, set: { c in Task { await model.selectChart(c) } })) {
                ForEach(InvestmentsChart.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let prices = model.selectedPrices {
                priceBody(prices)
            } else {
                valueBody
            }
            Text(model.chart.note).font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder private var valueBody: some View {
        if let error = content.seriesError {
            Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
        } else {
            let known = InvestmentsChart.known(content.series)
            if known.count >= 2 {
                valueChart(known)
            } else {
                Text(InvestmentsChart.tooFewMessage).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder private func priceBody(_ state: LoadState<[MetalPricePoint]>) -> some View {
        if let points = state.value {
            let known = InvestmentsChart.known(points)
            if known.count >= 2 {
                priceChart(known)
            } else {
                Text(InvestmentsChart.tooFewMessage).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        } else if let error = state.errorMessage {
            Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private func valueChart(_ points: [HoldingValuePoint]) -> some View {
        Chart {
            ForEach(points) { p in
                if let value = p.valueAed {
                    LineMark(x: .value("Day", p.date.startDate, unit: .day), y: .value("AED", value.chartValue),
                             series: .value("Line", "Value"))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                }
                if let cost = p.costAed {
                    LineMark(x: .value("Day", p.date.startDate, unit: .day), y: .value("AED", cost.chartValue),
                             series: .value("Line", "Cost"))
                        .foregroundStyle(Palette.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartForegroundStyleScale(["Value": Palette.accent, "Cost": Palette.muted])
        .chartLegend(position: .top, alignment: .leading)
        .modifier(DayAxes())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Investments value against cost over the last \(InvestmentsChart.days) days")
        .accessibilityValue(points.last?.valueAed.map { "Latest \(MoneyFormat.aed($0))" } ?? "")
    }

    private func priceChart(_ points: [MetalPricePoint]) -> some View {
        Chart(points) { p in
            if let price = p.aedPerGram {
                LineMark(x: .value("Day", p.date.startDate, unit: .day), y: .value("AED per gram", price.chartValue))
                    .foregroundStyle(Palette.accent)
                    .interpolationMethod(.monotone)
            }
        }
        .modifier(DayAxes())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.chart.title) price per gram over the last \(InvestmentsChart.days) days")
        .accessibilityValue(points.last?.aedPerGram.map { "Latest \(HoldingsText.perGram($0))" } ?? "")
    }
}

/// Months along the bottom, compact AED up the side, the scale following the figures.
private struct DayAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisGridLine().foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(LedgerDates.monthAbbrev(CalendarDay(date: date))) }
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
            .frame(height: 180)
    }
}
