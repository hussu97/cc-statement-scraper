import Charts
import LedgerKit
import SwiftUI

/// Net worth month by month (each month's last nightly snapshot, then today). A new ledger has
/// only today, so the card says where history comes from instead of drawing one dot.
struct NetWorthChartCard: View {
    let points: [NetWorthPoint]

    var body: some View {
        Card {
            SectionHeader(title: "Net worth over time")
            if NetWorthHistory.showsChart(points) {
                chart
            }
            Text(NetWorthHistory.note(points)).font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }

    private var chart: some View {
        // Months as categories (one mark per month, labels under them); the scale follows the
        // figures rather than starting at zero, so a month's change is visible.
        Chart(points) { point in
            LineMark(x: .value("Month", point.monthLabel), y: .value("AED", point.netAed.chartValue))
                .foregroundStyle(Palette.accent)
                .interpolationMethod(.monotone)
            PointMark(x: .value("Month", point.monthLabel), y: .value("AED", point.netAed.chartValue))
                .foregroundStyle(point.isLive ? Palette.accent : Palette.ink2)
                .symbolSize(point.isLive ? 60 : 30)
        }
        .chartXScale(domain: points.map(\.monthLabel))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(MoneyFormat.compact(Decimal(Int(v)))) }
                }
            }
        }
        .frame(height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Net worth over time")
        .accessibilityValue(points.map(\.accessibilityValue).joined(separator: "; "))
    }
}

/// An account's end-of-day balance over the last 90 days.
struct BalanceChartCard: View {
    let series: LoadState<[BalancePoint]>
    var currency = "AED"

    var body: some View {
        Card {
            SectionHeader(title: "Balance", trailing: "Last \(BalanceSeries.days) days")
            if let points = series.value {
                if BalanceSeries.showsChart(points) { chart(BalanceSeries.known(points)) }
                Text(BalanceSeries.note(points)).font(Typography.caption).foregroundStyle(Palette.muted)
            } else if let error = series.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func chart(_ known: [(date: CalendarDay, balance: Decimal)]) -> some View {
        Chart(known, id: \.date) { point in
            LineMark(x: .value("Day", point.date.startDate, unit: .day),
                     y: .value("Balance", point.balance.chartValue))
                .foregroundStyle(Palette.accent)
                .interpolationMethod(.stepEnd)
        }
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
                    if let v = value.as(Double.self) { Text(MoneyFormat.compact(Decimal(Int(v)))) }
                }
            }
        }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Balance over the last \(BalanceSeries.days) days")
        .accessibilityValue(known.last.map { "Latest \(MoneyFormat.amount($0.balance, currency: currency))" } ?? "")
    }
}
