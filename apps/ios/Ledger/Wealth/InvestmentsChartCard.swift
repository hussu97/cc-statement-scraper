import Charts
import LedgerKit
import SwiftUI

/// The holdings' value against their cost over the period on screen (the same days as the
/// returns below it). Every point is the server's; a day without one is left out.
struct InvestmentsChartCard: View {
    let model: InvestmentsModel

    var body: some View {
        Card {
            SectionHeader(title: "Value", trailing: InvestmentsChart.spanTitle(model.period))
            switch model.selectedSeries {
            case .failed(let message, nil):
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
            default:
                if let series = model.selectedSeries.value {
                    let known = InvestmentsChart.known(series)
                    if known.count >= 2 {
                        valueChart(known)
                    } else {
                        Text(InvestmentsChart.tooFewMessage).font(Typography.caption).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    }
                    Text(InvestmentsChart.note).font(Typography.caption).foregroundStyle(Palette.muted)
                    if let partial = InvestmentsChart.partialNote(series) {
                        Text(partial).font(Typography.caption).foregroundStyle(Palette.warn)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
            }
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
        .modifier(DayAxes(short: model.period == .thirtyDays))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Investments value against cost over \(InvestmentsChart.span(model.period))")
        .accessibilityValue(points.last?.valueAed.map { "Latest \(MoneyFormat.aed($0))" } ?? "")
    }
}

/// Months (or weeks) along the bottom, compact AED up the side, the scale following the figures.
private struct DayAxes: ViewModifier {
    /// 30 days: a week per mark, labelled by day; longer spans a month per mark.
    var short = false

    func body(content: Content) -> some View {
        content
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .stride(by: short ? .weekOfYear : .month)) { value in
                    AxisGridLine().foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(short ? LedgerDates.dayLabel(CalendarDay(date: date)) : LedgerDates.monthAbbrev(CalendarDay(date: date)))
                        }
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
