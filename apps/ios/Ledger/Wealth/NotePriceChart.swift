import Charts
import LedgerKit
import SwiftUI

/// Each share's closes since the strike in % of its initial level, with the live levels as rules.
struct NoteChart: View {
    let lines: [NoteSeriesLine]
    let levels: [NoteDetail.Level]
    private static let colors: [Color] = [ChartPalette.cat4, ChartPalette.cat1, ChartPalette.cat7, ChartPalette.cat12,
                                          ChartPalette.cat3, ChartPalette.cat9]

    var body: some View {
        Chart {
            ForEach(lines) { line in
                ForEach(line.points, id: \.day) { p in
                    LineMark(x: .value("Day", p.day.startDate), y: .value("% of initial", p.pct.chartValue))
                        .foregroundStyle(by: .value("Share", line.symbol))
                        .interpolationMethod(.linear)
                }
            }
            ForEach(levels) { level in
                RuleMark(y: .value(NoteText.levelLabel(level), level.pct.chartValue))
                    .foregroundStyle(Palette.borderStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(domain: lines.map(\.symbol), range: Array(Self.colors.prefix(max(lines.count, 1))))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(ChartPalette.grid)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .environment(\.timeZone, LedgerDates.timeZone)
        .environment(\.calendar, LedgerDates.calendar)
        .frame(height: 220)
        .accessibilityLabel("Each share's closes since the strike, in percent of its initial level")
    }
}
