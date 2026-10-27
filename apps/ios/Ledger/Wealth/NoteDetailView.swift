import LedgerKit
import SwiftUI

/// One structured note: where it stands (invested, received, if it ended today, break-even), the
/// next observation at today's prices, the shares against the barriers, what it can pay, its
/// schedule with outcomes and its terms. Owners update prices and remove a note added by mistake.
/// Every figure is the server's; the words are LedgerKit's.
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
                StatGrid(stats: note.summaryStats)
                if !note.isEnded { NextCard(note: note) }
                NoteSharesCard(note: note)
                if note.scenarios != nil { NoteScenariosCard(note: note) }
                NoteScheduleCard(note: note)
                NoteTermsCard(note: note)
                if model.canRemove(canEdit: canEdit) {
                    Button("Remove this note…", role: .destructive) { confirmingRemove = true }
                        .font(Typography.rowMeta)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(minHeight: Metrics.tapMin)
                }
            }
            .padding(.top, 8)
        }
        .ledgerNavigation(model.state.value?.summary.name ?? "Structured note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canRefreshPrices(canEdit: canEdit) {
                ToolbarItem(placement: .primaryAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.refreshPrices(profileCode: profileCode, canEdit: canEdit) }
                        } label: { Label("Update prices", systemImage: "arrow.clockwise") }
                    }
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
        .alert("Couldn't remove it", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// The name, status and issuer line.
private struct NoteHeader: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.summary.name).font(Typography.display).foregroundStyle(Palette.ink)
                .lineLimit(3).minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                Chip(label: note.summary.noteStatus.label, tone: note.summary.noteStatus.tone)
                if note.summary.awaitingPrices { Chip(label: "Awaiting prices", tone: .warn) }
            }
            if !note.headerDetail.isEmpty {
                Text(note.headerDetail).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// Stat tiles, two to a row.
struct StatGrid: View {
    let stats: [NoteStat]

    var body: some View {
        Card {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 16) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stat.label.uppercased()).font(Typography.caption).tracking(0.8).foregroundStyle(Palette.muted)
                        Text(stat.value).font(Typography.amount)
                            .foregroundStyle(stat.tone == .neutral ? Palette.ink : stat.tone.color).moneyLine()
                        if let sub = stat.sub {
                            Text(sub).font(Typography.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The next observation: the coupon and autocall at today's prices, and the worst share now.
private struct NextCard: View {
    let note: NoteDetail

    var body: some View {
        Card {
            Text("NEXT OBSERVATION").font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
            Text(note.nextTitle).font(Typography.sectionTitle).foregroundStyle(Palette.ink)
            ForEach(note.outlooks) { outlook in
                VStack(alignment: .leading, spacing: 3) {
                    Text(outlook.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(outlook.text).font(Typography.rowMeta)
                        .foregroundStyle(outlook.ok ? Palette.positive : Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(outlook.ok ? Palette.positiveSoft : Palette.warnSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
                .accessibilityElement(children: .combine)
            }
            if let worst = note.worstNowText {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Worst share now").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    Text(worst).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
