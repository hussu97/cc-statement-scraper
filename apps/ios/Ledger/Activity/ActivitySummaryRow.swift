import LedgerKit
import SwiftUI

/// The header above the list: count, net AED and date span of the matching rows.
/// Redacted while loading; absent when the summary failed.
struct ActivitySummaryRow: View {
    let display: ActivitySummaryDisplay

    var body: some View {
        switch display {
        case .hidden:
            EmptyView()
        case .placeholder:
            content(ActivitySummaryHeader(ActivitySummary(
                txnCount: 100, netAed: 1000, earliestDate: CalendarDay(year: 2026, month: 1, day: 1),
                latestDate: CalendarDay(year: 2026, month: 1, day: 31))))
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading summary")
        case .shown(let header):
            content(header)
        }
    }

    private func content(_ h: ActivitySummaryHeader) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(h.countText).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text(h.netText).font(Typography.amount).moneyLine()
                    .foregroundStyle(h.isNetCredit ? Palette.positive : Palette.ink)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(h.dateRangeText ?? "")
                Spacer(minLength: 8)
                Text(h.unpricedNote ?? "net")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
    }
}
