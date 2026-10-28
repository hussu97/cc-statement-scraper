import Charts
import LedgerKit
import SwiftUI

/// India's value against what its open positions cost, over the period the picker shows. Every
/// point is `india_overview`'s; a day without one is left out.
struct IndiaChartCard: View {
    let model: IndiaModel

    var body: some View {
        Card {
            SectionHeader(title: "Value", trailing: InvestmentsChart.spanTitle(model.period))
            switch model.selected {
            case .failed(let message, nil):
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
            default:
                if let overview = model.selected.value {
                    let known = IndiaChart.known(overview.series)
                    if known.count >= 2 {
                        chart(known, currency: overview.currency)
                    } else {
                        Text(IndiaChart.tooFewMessage).font(Typography.caption).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    }
                    Text(IndiaChart.note).font(Typography.caption).foregroundStyle(Palette.muted)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
    }

    private func chart(_ points: [IndiaOverview.Point], currency: String) -> some View {
        Chart {
            ForEach(points) { p in
                if let value = p.value {
                    LineMark(x: .value("Day", p.date.startDate, unit: .day), y: .value(currency, value.chartValue),
                             series: .value("Line", "Value"))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                }
                if let invested = p.invested {
                    LineMark(x: .value("Day", p.date.startDate, unit: .day), y: .value(currency, invested.chartValue),
                             series: .value("Line", "Invested"))
                        .foregroundStyle(Palette.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartForegroundStyleScale(["Value": Palette.accent, "Invested": Palette.muted])
        .chartLegend(position: .top, alignment: .leading)
        .modifier(DayAxes(short: model.period == .thirtyDays))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kite and Coin value against invested over \(InvestmentsChart.span(model.period))")
        .accessibilityValue(points.last?.value.map { "Latest \(NoteText.whole($0, currency: currency))" } ?? "")
    }
}

/// The period's figures in rupees: value at start, money added, value now, growth and return.
struct IndiaPeriodCard: View {
    let model: IndiaModel
    let profileCode: String

    var body: some View {
        Card {
            SectionHeader(title: "Returns", trailing: model.selected.value.flatMap(IndiaPeriod.rangeText))
            switch model.selected {
            case .failed(let message, nil):
                Text(message).font(Typography.caption).foregroundStyle(Palette.danger)
                Button("Try again") { Task { await model.select(model.period, profileCode: profileCode) } }
                    .buttonStyle(.bordered).tint(Palette.accent)
            default:
                if let overview = model.selected.value {
                    let lines = IndiaPeriod.lines(overview)
                    if lines.isEmpty {
                        Text(IndiaPeriod.emptyMessage).font(Typography.caption).foregroundStyle(Palette.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lines) { line in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(line.label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                                    Spacer()
                                    Text(line.text).font(Typography.amount).moneyLine()
                                        .foregroundStyle(line.tone == .neutral ? Palette.ink : line.tone.color)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Text(IndiaPeriod.note).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
    }
}
