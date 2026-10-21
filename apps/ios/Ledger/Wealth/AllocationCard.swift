import Charts
import LedgerKit
import SwiftUI

/// Wealth Overview's allocation: what you own by class (cash, gold, silver, plans, broker accounts,
/// shares and funds, deposits) as a donut with a legend of values and shares, and what the cards
/// owe as its own negative line under it. Every figure and share is the server's (`net_worth`).
struct AllocationCard: View {
    let slices: [AllocationSlice]

    var body: some View {
        let assets = Allocation.assets(slices)
        if !assets.isEmpty {
            Card {
                SectionHeader(title: "Allocation")
                if Allocation.showsChart(slices) { chart(assets) }
                VStack(spacing: 8) {
                    ForEach(assets) { slice in legendRow(slice) }
                    if let owed = Allocation.owed(slices) {
                        Divider().overlay(Palette.border)
                        legendRow(owed)
                    }
                }
                Text(Allocation.note).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private func chart(_ assets: [AllocationSlice]) -> some View {
        Chart(assets) { slice in
            SectorMark(angle: .value("AED", slice.valueAed.chartValue), innerRadius: .ratio(0.6), angularInset: 1.5)
                .foregroundStyle(ChartPalette.color(for: slice.colorToken))
                .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Allocation by asset class")
        .accessibilityValue(assets.map(\.accessibilityLabel).joined(separator: "; "))
    }

    private func legendRow(_ slice: AllocationSlice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if slice.isOwed {
                Image(systemName: "minus.circle").font(.caption).foregroundStyle(Palette.danger)
            } else {
                Circle().fill(ChartPalette.color(for: slice.colorToken)).frame(width: 10, height: 10)
            }
            Text(slice.label).font(Typography.rowMeta).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if let share = slice.shareText {
                Text(share).font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit()
            }
            Text(slice.valueText).font(Typography.amount).moneyLine()
                .foregroundStyle(slice.isOwed ? Palette.danger : Palette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slice.accessibilityLabel)
    }
}
