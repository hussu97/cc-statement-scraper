import LedgerKit
import SwiftUI

/// Where a row on a broker account's tabs leads: a note's screen or a holding's.
enum AccountRoute: Hashable, Identifiable {
    case note(String)
    case holding(String)
    var id: Self { self }
}

/// Portfolio: "Your notes", a card per live note (its verdict, two numbers, its stocks on bars),
/// then "Other holdings", a line each. The words and which row goes where are LedgerKit's.
struct BrokerPortfolioTab: View {
    let p: BrokerPortfolioPresentation
    let open: (AccountRoute) -> Void

    var body: some View {
        let notes = p.notes
        let others = p.otherHoldings
        if notes.isEmpty && others.isEmpty {
            EmptyCard(systemImage: "tray", message: p.positionsEmptyMessage)
        }
        if !notes.isEmpty {
            SectionHeader(title: "Your notes", trailing: "\(notes.count)")
            ForEach(notes) { card in
                Button { open(.note(card.holdingCode)) } label: { BrokerNoteCardView(card: card) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the note")
            }
        }
        if !others.isEmpty {
            Card {
                SectionHeader(title: "Other holdings", trailing: "\(others.count)")
                ForEach(others) { row in
                    if row.id != others.first?.id { Divider().overlay(Palette.border) }
                    Button { open(row.opensNote ? .note(row.holdingCode) : .holding(row.holdingCode)) } label: {
                        HoldingLine(row: row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One live note: name, verdict, worth today next to if called (or paid), its stocks.
private struct BrokerNoteCardView: View {
    let card: BrokerNoteCard

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Text(card.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).padding(.top, 4)
            }
            if let verdict = card.verdict {
                Text(verdict).font(Typography.rowMeta.weight(.semibold))
                    .foregroundStyle(card.verdictTone == .neutral ? Palette.ink : card.verdictTone.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(card.figures) { figure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(figure.label).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(figure.value).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                        if let sub = figure.sub {
                            Text(sub).font(Typography.caption)
                                .foregroundStyle(figure.tone == .neutral ? Palette.muted : figure.tone.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if !card.bars.isEmpty { NoteStockBars(bars: card.bars, showsLegend: false) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
    }
}

/// Another holding in one line: name, value, profit.
private struct HoldingLine: View {
    let row: BrokerHoldingRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                    if let profit = row.profitText {
                        Text(profit).font(Typography.caption).foregroundStyle(row.profitTone.color).moneyLine()
                    }
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

/// Past notes: what everything that ended came to, then a line each.
struct BrokerPastNotesTab: View {
    let p: BrokerPortfolioPresentation
    let open: (AccountRoute) -> Void

    var body: some View {
        let rows = p.past
        Card {
            if let summary = p.pastSummary {
                Text(summary).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                Divider().overlay(Palette.border)
                Button { open(row.opensNote ? .note(row.holdingCode) : .holding(row.holdingCode)) } label: {
                    PastLine(row: row)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PastLine: View {
    let row: BrokerPastRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
                    if let held = row.heldText {
                        Text(held).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.profitText).font(Typography.amount).foregroundStyle(row.profitTone.color).moneyLine()
                    if let ret = row.returnText {
                        Text(ret).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                    }
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
