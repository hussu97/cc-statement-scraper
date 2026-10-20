import LedgerKit
import SwiftUI

/// The selected month's cash flow in its groups with the server's net, then the last months
/// with their net; tapping one shows it. Grouping and words are `CashFlow`'s.
struct CashFlowCard: View {
    let model: CashModel
    let content: CashModel.Content
    let retry: () -> Void

    var body: some View {
        Card {
            SectionHeader(title: LedgerDates.monthTitle(model.selectedMonth))
            if let error = content.flowError {
                Label("Couldn't load cash flow", systemImage: "exclamationmark.triangle")
                    .font(Typography.rowTitle).foregroundStyle(Palette.danger)
                Text(error).font(Typography.caption).foregroundStyle(Palette.muted)
                Button("Try again", action: retry).buttonStyle(.bordered).tint(Palette.accent)
            } else if let month = model.selected {
                if month.isEmpty {
                    Text(model.emptyMessage(for: month.month)).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                } else {
                    ForEach(month.groups) { group in GroupBlock(group: group) }
                }
                if let net = month.netText {
                    Divider().overlay(Palette.border)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Net").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Spacer()
                        if month.isPartial { Chip(label: CashFlow.partialLabel) }
                        Text(net).font(Typography.amount).foregroundStyle(month.netTone.color).moneyLine()
                    }
                    .accessibilityElement(children: .combine)
                    // Before the first bank evidence a month has card spend and no income: not a loss.
                    Text(month.isPartial ? CashFlow.partialNote : "Money in, less spending, commitments and unfiled money out.")
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
        }
        if content.flowError == nil {
            Card {
                SectionHeader(title: "Months")
                ForEach(model.monthNets) { month in
                    MonthRow(month: month, isSelected: month.month == model.selectedMonth) {
                        model.selectedMonth = month.month
                    }
                    if month.id != model.monthNets.last?.id { Divider().overlay(Palette.border) }
                }
            }
        }
    }
}

private struct GroupBlock: View {
    let group: CashFlowGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.kind.title.uppercased())
                .font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
            ForEach(group.lines) { line in
                AdaptiveRow(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.label).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(line.countText).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                } trailing: {
                    Text(line.amountText).font(Typography.amount)
                        .foregroundStyle(group.kind.tone == .positive ? Palette.positive : Palette.ink)
                        .moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
            if let note = group.kind.note {
                Text(note).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct MonthRow: View {
    let month: CashFlowMonth
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Spacer()
                Text(month.listText ?? "Nothing moved")
                    .font(month.netText == nil || month.isPartial ? Typography.rowMeta : Typography.amount)
                    .foregroundStyle(month.netText == nil || month.isPartial ? Palette.muted : month.netTone.color)
                    .moneyLine()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.borderStrong)
            }
            .frame(minHeight: Metrics.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
