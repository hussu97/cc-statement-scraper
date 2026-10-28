import LedgerKit
import SwiftUI

/// Kite or Coin's holdings, every open position sortable by value, P&L %, today, weight or name;
/// each row shows the figure it is sorted by and opens the position. Rows and order are
/// LedgerKit's (`BrokerPortfolioPresentation.holdingRows`).
struct BrokerHoldingsList: View {
    let p: BrokerPortfolioPresentation
    let open: (String) -> Void
    @State private var sort: BrokerHoldingSort = .value

    var body: some View {
        let rows = p.holdingRows(sort: sort)
        if rows.isEmpty {
            EmptyCard(systemImage: "tray", message: p.positionsEmptyMessage)
        } else {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Holdings", trailing: "\(rows.count)")
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(BrokerHoldingSort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(sort.title, systemImage: "arrow.up.arrow.down").font(Typography.caption)
                    }
                    .accessibilityLabel("Sort by \(sort.title)")
                }
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                    Button { if let isin = row.isin { open(isin) } } label: { PositionLine(row: row) }
                        .buttonStyle(.plain)
                        .disabled(row.isin == nil)
                }
            }
        }
    }
}

/// One position: name and what it is on the left; value and the sorted-by figure on the right.
private struct PositionLine: View {
    let row: BrokerPositionRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(row.subtitle).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                    Text(row.figureText).font(Typography.caption)
                        .foregroundStyle(row.figureTone == .neutral ? Palette.muted : row.figureTone.color).moneyLine()
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
