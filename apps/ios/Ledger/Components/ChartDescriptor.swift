import Accessibility
import LedgerKit
import SwiftUI

/// Turns LedgerKit's `ChartAccessibility` into an audio graph and data table
/// for VoiceOver (`.accessibilityChartDescriptor`). BACKLOG IOS-20r, chart part.
struct ChartDescriptor: AXChartDescriptorRepresentable {
    let data: ChartAccessibility

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: data.xTitle, categoryOrder: data.categories)
        let y = AXNumericDataAxisDescriptor(title: data.yTitle, range: 0...data.yMax, gridlinePositions: []) { value in
            MoneyFormat.aed(Decimal(Int(value.rounded())), fractionDigits: 0)
        }
        let series = data.series.map { s in
            AXDataSeriesDescriptor(name: s.name, isContinuous: false,
                                   dataPoints: zip(data.categories, s.values).map { .init(x: $0, y: $1) })
        }
        return AXChartDescriptor(title: data.title, summary: data.summary, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: series)
    }
}

extension View {
    /// The chart's VoiceOver descriptor plus a one-line label.
    func chartAccessibility(_ data: ChartAccessibility) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(data.title)
            .accessibilityValue(data.summary)
            .accessibilityChartDescriptor(ChartDescriptor(data: data))
    }
}
