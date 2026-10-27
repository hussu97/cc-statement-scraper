import LedgerKit
import SwiftUI
import UniformTypeIdentifiers

/// Add a structured note (owners): choose its term sheet (PDF), wait while it is read, then review
/// the name, the shares' price symbols, the schedule and payout as read, and say what was bought
/// and from which account. Saving opens the note (`saved`). `AddNoteModel` decides.
struct AddNoteSheet: View {
    let model: AddNoteModel
    let profileCode: String
    let canEdit: Bool
    /// The new note's holding code, once saved.
    let saved: (String) -> Void
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { ErrorSection(text: error) }
                switch model.phase {
                case .choosing: choose
                case .extracting: extracting
                case .review: if let draft = model.draft { NoteReviewSections(model: model, draft: draft) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(AddNoteModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.phase == .review {
                    SheetToolbar(isSaving: model.isSaving, saveLabel: "Save note", save: save, cancel: { dismiss() })
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                Task { await model.extract(url: url, profileCode: profileCode, canEdit: canEdit) }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSaving || model.phase == .extracting)
    }

    private var choose: some View {
        Section {
            Button { picking = true } label: { Label("Choose the term sheet", systemImage: "doc.badge.plus") }
        } footer: {
            Text(AddNoteModel.chooseHint)
        }
    }

    private var extracting: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading the term sheet…").font(Typography.rowTitle)
            }
        } footer: {
            Text(AddNoteModel.extractingHint)
        }
    }

    private func save() {
        Task {
            if let code = await model.save(profileCode: profileCode, canEdit: canEdit) {
                dismiss()
                saved(code)
            }
        }
    }
}

/// The review: what was read (name editable, the shares' symbols editable) and what was bought.
private struct NoteReviewSections: View {
    let model: AddNoteModel
    let draft: NoteDraft

    var body: some View {
        @Bindable var model = model
        if !model.warnings.isEmpty {
            Section {
                ForEach(model.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(Typography.rowMeta).foregroundStyle(Palette.warn)
                }
            } header: { Text("Check before saving") }
        }
        Section {
            TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.setName($0) }))
            Text(draft.termsSummary).font(Typography.caption).foregroundStyle(Palette.muted)
        } header: { Text("The note") } footer: { Text(draft.terms.productName) }
        Section {
            ForEach(Array(draft.terms.underlyings.enumerated()), id: \.offset) { i, u in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(u.name).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("Initial \(u.initialLevel)").font(Typography.caption).foregroundStyle(Palette.muted).monospacedDigit()
                    }
                    TextField("Symbol, e.g. AMZN", text: Binding(
                        get: { model.draft?.terms.underlyings[i].symbol ?? "" }, set: { model.setSymbol(i, $0) }))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .foregroundStyle(u.symbol.isEmpty ? Palette.danger : Palette.ink)
                        .accessibilityLabel("\(u.name) price symbol")
                }
            }
        } header: { Text("Underlying shares") } footer: { Text(AddNoteModel.symbolHint) }
        Section {
            Text(draft.scheduleSummary).font(Typography.rowMeta)
            ForEach(draft.payoutRows, id: \.when) { row in
                Text("\(row.when): \(row.pays)\(row.physical ? " in shares" : "")").font(Typography.caption)
            }
        } header: { Text("Schedule and payout") } footer: { Text(AddNoteModel.scheduleFooter) }
        Section {
            TextField(model.amountLabel, text: $model.form.investedAmount)
                .keyboardType(.decimalPad).monospacedDigit()
            TextField("Price paid (%), \(model.pricePlaceholder) if empty", text: $model.form.purchasePricePct)
                .keyboardType(.decimalPad).monospacedDigit()
            DatePicker("Trade date", selection: Binding(get: { model.form.tradeDate.startDate },
                                                        set: { model.form.tradeDate = CalendarDay(date: $0) }),
                       displayedComponents: .date)
                .environment(\.timeZone, LedgerDates.timeZone)
            Picker("Paid from", selection: $model.form.fundingAccountCode) {
                Text("Not tracked").tag(String?.none)
                ForEach(model.accounts) { a in
                    Text("\(a.bankCode) · \(a.title) (\(a.currency))").tag(Optional(a.accountCode))
                }
            }
            .disabled(model.accounts.isEmpty)
        } header: { Text("What you bought") } footer: { Text(model.accountHint) }
    }
}
