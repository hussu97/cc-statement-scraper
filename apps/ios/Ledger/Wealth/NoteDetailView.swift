import LedgerKit
import SwiftUI

/// One structured note, one question first: how is it doing? The name and status, the verdict in
/// big words with when the next check is, its stocks on bars, then the money in three numbers
/// (paid, worth today, if called; once ended: paid, got back, profit). The rest (every scenario,
/// the full schedule, the price history, the terms) waits collapsed. Owners update prices or
/// remove a note added by mistake from the "…" menu. Every figure is the server's; the words and
/// what shows are LedgerKit's.
struct NoteDetailView: View {
    let profileCode: String
    let canEdit: Bool
    /// @State, not let: kept across the parent's re-renders, so the loaded note isn't thrown away.
    @State private var model: NoteDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false
    @State private var removeError: String?

    init(notes: NotesModel, holdingCode: String, profileCode: String, canEdit: Bool) {
        self.profileCode = profileCode
        self.canEdit = canEdit
        _model = State(initialValue: notes.detailModel(for: holdingCode))
    }

    var body: some View {
        Page {
            if let notice = model.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { note in
                NoteHeader(note: note)
                VerdictBlock(note: note)
                let bars = note.bars
                if !bars.isEmpty {
                    Card {
                        SectionHeader(title: "The stocks")
                        NoteStockBars(bars: bars)
                    }
                }
                Card { StatTiles(stats: note.moneyStats(), columns: 3) }
                NoteDetailSections(note: note, termSheetLoading: model.termSheet.isLoading) {
                    Task { await model.openTermSheet() }
                }
            }
            .padding(.top, 8)
        }
        .ledgerNavigation(model.state.value?.summary.name ?? "Structured note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSaving {
                ToolbarItem(placement: .primaryAction) { ProgressView() }
            } else if model.canRefreshPrices(canEdit: canEdit) || model.canRemove(canEdit: canEdit) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if model.canRefreshPrices(canEdit: canEdit) {
                            Button {
                                Task { await model.refreshPrices(profileCode: profileCode, canEdit: canEdit) }
                            } label: { Label("Update prices", systemImage: "arrow.clockwise") }
                        }
                        if model.canRemove(canEdit: canEdit) {
                            Button(role: .destructive) { confirmingRemove = true } label: {
                                Label("Remove note…", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Note actions")
                }
            }
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
        .confirmationDialog(NoteDetailModel.removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    removeError = await model.remove(profileCode: profileCode, canEdit: canEdit)
                    if removeError == nil { dismiss() }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(NoteDetailModel.removeMessage)
        }
        .sheet(item: Binding(get: { model.termSheet.document },
                             set: { if $0 == nil { model.termSheet.close() } })) { document in
            TermSheetSheet(document: document)
        }
        .alert("Couldn't open the term sheet", isPresented: Binding(get: { model.termSheet.errorMessage != nil },
                                                                    set: { if !$0 { model.termSheet.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.termSheet.errorMessage ?? "")
        }
        .alert("Couldn't remove it", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// The name, a small status badge and one muted line (issuer · ISIN).
private struct NoteHeader: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.summary.name).font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Chip(label: note.summary.noteStatus.label, tone: note.summary.noteStatus.tone)
                if note.summary.awaitingPrices { Chip(label: "Awaiting prices", tone: .warn) }
            }
            if !note.headerDetail.isEmpty {
                Text(note.headerDetail).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
    }
}

/// The verdict in big words, coloured by its tone, and the countdown under it.
private struct VerdictBlock: View {
    let note: NoteDetail

    var body: some View {
        let headline = note.verdictHeadline()
        let lines = note.countdown()
        if headline != nil || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let headline {
                    Text(headline).font(Typography.amountLarge)
                        .foregroundStyle(note.verdictTone == .neutral ? Palette.ink : note.verdictTone.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Every scenario, the full schedule, the price history and the terms (with the term sheet,
/// which opens in the app), each collapsed.
private struct NoteDetailSections: View {
    let note: NoteDetail
    let termSheetLoading: Bool
    let openTermSheet: () -> Void

    var body: some View {
        let sections = note.sections
        Card {
            ForEach(sections) { section in
                if section != sections.first { Divider().overlay(Palette.border) }
                DisclosureGroup {
                    content(section).padding(.top, 8)
                } label: {
                    Text(section.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        .frame(minHeight: Metrics.tapMin)
                }
                .tint(Palette.ink2)
            }
        }
    }

    @ViewBuilder private func content(_ section: NoteSection) -> some View {
        switch section {
        case .scenarios: NoteScenariosContent(note: note)
        case .schedule: NoteScheduleContent(note: note)
        case .priceHistory: NoteChart(lines: note.seriesLines, levels: note.isEnded ? [] : note.levels ?? [])
        case .terms:
            VStack(alignment: .leading, spacing: 8) {
                NoteTermsContent(note: note)
                TermSheetRow(note: note, isLoading: termSheetLoading, open: openTermSheet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
