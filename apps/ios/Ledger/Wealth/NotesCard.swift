import LedgerKit
import SwiftUI

/// Live structured notes in a short list, each in a few words: its name, its verdict and what it
/// is worth today. Never ended ones. Which notes are listed is LedgerKit's (`NoteListRow.rows`).
struct NotesCard: View {
    let rows: [NoteListRow]
    var trailing: String?
    let open: (String) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Structured notes", trailing: trailing)
            ForEach(rows) { row in
                if row.id != rows.first?.id { Divider().overlay(Palette.border) }
                Button { open(row.holdingCode) } label: { NoteLine(row: row) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the note")
            }
        }
    }
}

/// One note: name and verdict; worth today (or paid) on the right.
private struct NoteLine: View {
    let row: NoteListRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AdaptiveRow(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(Typography.rowMeta).foregroundStyle(Palette.ink).lineLimit(2)
                    if let verdict = row.verdict {
                        Text(verdict).font(Typography.caption)
                            .foregroundStyle(row.verdictTone == .neutral ? Palette.muted : row.verdictTone.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.valueText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                    Text(row.valueLabel).font(Typography.caption).foregroundStyle(Palette.muted)
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
