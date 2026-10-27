import LedgerKit
import SwiftUI

/// Structured notes: live first, then ended. On Investments every note; on an account screen
/// (`fundingAccount`) the notes paid from it. Each row opens the note. Words are LedgerKit's.
struct NotesCard: View {
    let model: NotesModel
    let profileCode: String
    let canEdit: Bool
    var fundingAccount: String?
    let add: () -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Structured notes", trailing: fundingAccount == nil ? nil : "Paid from this account")
            switch model.state {
            case .idle, .loading(previous: nil):
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading…").font(Typography.rowMeta).foregroundStyle(Palette.muted)
                }
            case .failed(let message, previous: nil):
                Text(message).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                Button("Try again") { Task { await model.load(profileCode: profileCode) } }
                    .buttonStyle(.bordered).tint(Palette.accent)
            default:
                rows(model.groups(fundingAccount: fundingAccount))
            }
            if canEdit {
                Button(action: add) { Label("Add from term sheet", systemImage: "doc.badge.plus") }
                    .buttonStyle(.bordered).tint(Palette.accent)
            }
        }
    }

    @ViewBuilder private func rows(_ groups: NoteGroups) -> some View {
        if groups.isEmpty {
            Text(NoteGroups.emptyMessage(canEdit: canEdit)).font(Typography.rowMeta).foregroundStyle(Palette.muted)
        }
        ForEach(groups.live) { note in
            if note.id != groups.live.first?.id { Divider().overlay(Palette.border) }
            link(note)
        }
        if !groups.ended.isEmpty {
            Text("ENDED").font(Typography.caption).tracking(1).foregroundStyle(Palette.muted).padding(.top, 4)
            ForEach(groups.ended) { note in
                if note.id != groups.ended.first?.id { Divider().overlay(Palette.border) }
                link(note)
            }
        }
    }

    private func link(_ note: NoteSummary) -> some View {
        NavigationLink {
            NoteDetailView(notes: model, holdingCode: note.holdingCode, profileCode: profileCode, canEdit: canEdit)
        } label: {
            NoteRow(note: note)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the note's barriers, next observation and scenarios")
    }
}

/// One note: name and status, its shares, the worst one and the next date with its outlook;
/// what went in and what came back; with a broker mark, sold today next to if called.
struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            let exits = note.exits()
            if !exits.isEmpty { NoteExitsView(exits: exits) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([note.accessibilityLabel] + note.exits().map(\.accessibilityLabel)).joined(separator: ", "))
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.name).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                HStack(spacing: 6) {
                    Chip(label: note.noteStatus.label, tone: note.noteStatus.tone)
                    if note.awaitingPrices { Chip(label: "Awaiting prices", tone: .warn) }
                    if let outlook = note.nextOutlook { Chip(label: outlook.text, tone: outlook.tone) }
                }
                Text(note.rowDetail()).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(note.money(note.invested)).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                Text(note.rowResult.text).font(Typography.caption).foregroundStyle(note.rowResult.tone.color).moneyLine()
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).padding(.top, 4)
        }
    }
}
