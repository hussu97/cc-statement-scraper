import LedgerKit
import SwiftUI

/// The positions at the latest marks, largest first: what each is, its value and what selling it
/// today makes; a note shows sold today next to if called, and opens its screen.
struct BrokerPositionsCard: View {
    let p: BrokerPortfolioPresentation
    let openNote: (String) -> Void

    var body: some View {
        let rows = p.positions
        Card {
            SectionHeader(title: "Positions", trailing: rows.isEmpty ? nil : "\(rows.count)")
            if rows.isEmpty {
                Text(p.positionsEmptyMessage).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            ForEach(rows) { row in
                if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                if row.opensNote {
                    Button { openNote(row.holdingCode) } label: { BrokerPositionRowView(row: row, chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the note's barriers, next observation and scenarios")
                } else {
                    BrokerPositionRowView(row: row, chevron: false)
                }
            }
            Text("Profit counts what each position has paid so far, against what went in.")
                .font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }
}

/// One position: name, quantity and price, its value and profit; a note's two ways out.
private struct BrokerPositionRowView: View {
    let row: BrokerPositionRow
    let chevron: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AdaptiveRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                        if let holding = row.holdingText {
                            Text(holding).font(Typography.caption).foregroundStyle(Palette.ink2).moneyLine()
                        }
                        if let caption = row.caption {
                            Text(caption).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        if !row.chips.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(row.chips, id: \.self) { Chip(label: $0.label, tone: $0.tone) }
                            }
                        }
                    }
                } trailing: {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                        if let profit = row.profitText {
                            Text(profit).font(Typography.caption).foregroundStyle(row.profitTone.color).moneyLine()
                        }
                        if let income = row.incomeText {
                            Text(income).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                        }
                    }
                }
                if chevron {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).padding(.top, 4)
                }
            }
            if !row.shares.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.shares) { share in
                        HStack(spacing: 8) {
                            Text(share.symbol).font(Typography.caption.weight(.medium))
                                .foregroundStyle(share.isWorst ? Palette.ink : Palette.ink2).frame(width: 48, alignment: .leading)
                            Text(share.levels).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                            Text(share.perf).font(Typography.caption).foregroundStyle(Palette.ink).moneyLine()
                            if let toCall = share.toCall {
                                Text(toCall).font(Typography.caption)
                                    .foregroundStyle(share.callMet ? Palette.positive : Palette.warn).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if !row.exits.isEmpty { NoteExitsView(exits: row.exits) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// The positions that ended, latest first: in, back and income, the profit and the return a year.
struct BrokerClosedCard: View {
    let rows: [BrokerClosedRow]
    let openNote: (String) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Ended positions", trailing: "\(rows.count)")
            ForEach(rows) { row in
                if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                if row.opensNote {
                    Button { openNote(row.holdingCode) } label: { ClosedRowView(row: row, chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the note")
                } else {
                    ClosedRowView(row: row, chevron: false)
                }
            }
        }
    }
}

private struct ClosedRowView: View {
    let row: BrokerClosedRow
    let chevron: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    Chip(label: row.status, tone: row.statusTone)
                    if let dates = row.dates {
                        Text(dates).font(Typography.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(row.flows).font(Typography.caption).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row.profitText).font(Typography.amount).foregroundStyle(row.profitTone.color).moneyLine()
                    if let ret = row.returnText {
                        Text(ret).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                    }
                }
            }
            if chevron {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
