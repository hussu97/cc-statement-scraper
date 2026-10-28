import LedgerKit
import SwiftUI

// Zerodha Kite and Coin in detail (tasks/todo.md §13): where the money sits, what stands out,
// Coin's SIPs. The words, the order and which rows show are LedgerKit's
// (`BrokerPortfolioPresentation`); these views lay them out.

/// Where the money sits: a bar of slices, then a line each. Coin can switch to fund houses.
struct BrokerAllocationCard: View {
    let p: BrokerPortfolioPresentation
    @State private var byHouse = false

    var body: some View {
        let rows = p.allocation(byHouse: byHouse)
        if !rows.isEmpty {
            Card {
                HStack {
                    SectionHeader(title: "Allocation")
                    if p.hasFundHouses {
                        Picker("Allocation by", selection: $byHouse) {
                            Text("Type").tag(false)
                            Text("Fund house").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(rows) { row in
                            Rectangle().fill(color(row)).frame(width: geo.size.width * row.share)
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .background(Capsule().fill(Palette.surface2))
                .accessibilityHidden(true)
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(color(row)).frame(width: 9, height: 9)
                            Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.weightText).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                            Text(row.valueText).font(Typography.rowMeta).foregroundStyle(Palette.ink).moneyLine()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func color(_ row: BrokerAllocationRow) -> Color {
        ChartPalette.color(for: ChartPalette.categoryTokens[row.colorIndex % ChartPalette.categoryTokens.count])
    }
}

/// Best and worst since bought, today's biggest moves, and how concentrated the account is. A
/// row opens its position.
struct BrokerHighlightsCard: View {
    let p: BrokerPortfolioPresentation
    let open: (String) -> Void

    var body: some View {
        let sections = p.highlightSections
        if !sections.isEmpty {
            Card {
                SectionHeader(title: "Highlights")
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(Typography.caption).foregroundStyle(Palette.muted)
                        ForEach(section.rows) { row in
                            Button { if let isin = row.isin { open(isin) } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(row.figureText).font(Typography.rowMeta)
                                        .foregroundStyle(row.tone == .neutral ? Palette.ink : row.tone.color).moneyLine()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let text = p.concentrationText {
                    Divider().overlay(Palette.border)
                    Text(text).font(Typography.caption).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Coin's SIPs: active first, a rejected instalment flagged with its reason.
struct BrokerSipsCard: View {
    let rows: [BrokerSipRow]
    var missedText: String?

    var body: some View {
        if !rows.isEmpty {
            Card {
                HStack {
                    Label("SIPs", systemImage: "repeat").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Spacer()
                    if let missedText { Badge(text: missedText, tone: .danger) }
                }
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(Typography.rowMeta.weight(.medium)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.schedule).font(Typography.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.statusText).font(Typography.caption)
                                .foregroundStyle(row.statusTone == .danger ? Palette.danger : Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let badge = row.badge { Badge(text: badge, tone: row.statusTone == .danger ? .danger : .neutral) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// A small pill: "Missed", "Paused", "2 instalments missed".
private struct Badge: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text).font(Typography.caption.weight(.medium))
            .foregroundStyle(tone == .neutral ? Palette.ink2 : tone.color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(tone == .danger ? Palette.dangerSoft : Palette.surface2))
    }
}
