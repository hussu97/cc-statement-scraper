import LedgerKit
import SwiftUI

/// The owner's transaction sheet (IOS-18): the category, searchable, with
/// "None" to clear a manual choice and merchant-wide by default; exclude from
/// spend; notes; then the details a viewer's sheet shows too (PAR-2).
/// `TransactionEditor` and `TransactionDetailModel` decide; viewers get
/// `TransactionDetailSheet` instead.
struct CategorySheet: View {
    @State private var editor: TransactionEditor
    /// Held as @State: the parent rebuilds this view whenever Activity re-renders (day totals,
    /// an edit, Realtime); a fresh model there would lose its loaded evidence and SMS (batch 7 audit).
    @State private var detail: TransactionDetailModel
    @Environment(\.dismiss) private var dismiss

    init(transaction: LedgerTransaction, categories: [FilterMeta.CategoryOption], profileCode: String,
         target: any TransactionEditing, detail: TransactionDetailModel) {
        _editor = State(initialValue: TransactionEditor(transaction: transaction, categories: categories,
                                                        profileCode: profileCode, target: target))
        _detail = State(initialValue: detail)
    }

    var body: some View {
        NavigationStack {
            List {
                if editor.showsDetails {
                    Section { TransactionDetailHeader(txn: transaction) }
                    TransactionDetailSections(model: detail) { EmptyView() }
                }
                categorySection
                if editor.showsDetails {
                    Section {
                        Toggle("Exclude from spend", isOn: Binding(get: { editor.excluded },
                                                                   set: { value in Task { await editor.setExcluded(value) } }))
                            .tint(Palette.accent)
                            .disabled(editor.busy != nil)
                    } footer: {
                        Text("For transfers or reimbursed purchases: they stay in Activity but leave spend totals.")
                    }
                    notesSection
                    TransactionEvidenceSection(model: detail)
                }
            }
            .task { await detail.load() }
            .onDisappear { detail.closeAllSMS() }
            .searchable(text: $editor.search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Find a category")
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Couldn't save", isPresented: Binding(get: { editor.errorMessage != nil },
                                                         set: { if !$0 { editor.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editor.errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private var transaction: LedgerTransaction { editor.transaction }

    private var categorySection: some View {
        Section {
            if editor.showsMerchantToggle {
                Toggle(editor.merchantToggleTitle, isOn: $editor.applyToMerchant)
                    .tint(Palette.accent)
                    .disabled(editor.busy != nil)
            }
            if editor.showsNone {
                categoryRow(code: nil, name: "None", token: nil, selected: editor.noneSelected)
                    .disabled(editor.busy != nil || !editor.canChooseNone)
            }
            if editor.categories.isEmpty {
                Text("Categories are loading…").foregroundStyle(Palette.muted)
            }
            ForEach(editor.visibleCategories) { category in
                categoryRow(code: category.categoryCode, name: category.name, token: category.colorToken,
                            selected: category.categoryCode == transaction.categoryCode)
                    .disabled(editor.busy != nil)
            }
            if let message = editor.noMatchMessage {
                Text(message).foregroundStyle(Palette.muted)
            }
        } header: {
            Text(editor.categoryHeader)
        } footer: {
            if editor.showsNone {
                Text("None clears your choice. A rule or suggestion can still categorise it.")
            }
        }
    }

    private func categoryRow(code: String?, name: String, token: String?, selected: Bool) -> some View {
        Button {
            Task { if await editor.choose(code) { dismiss() } }
        } label: {
            HStack {
                if code == nil {
                    Image(systemName: "circle.slash").font(.caption).foregroundStyle(Palette.muted)
                } else {
                    CategoryDot(token: token, size: 10)
                }
                Text(name).foregroundStyle(Palette.ink)
                Spacer()
                if editor.busy == .category(code) {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Add a note for yourself", text: $editor.notesDraft, axis: .vertical)
                .lineLimit(1...6)
                .disabled(editor.busy != nil)
            if editor.notesChanged {
                HStack {
                    Button("Cancel") { editor.discardNotes() }.buttonStyle(.borderless)
                    Spacer()
                    if editor.busy == .notes {
                        ProgressView()
                    } else {
                        Button("Save note") { Task { await editor.saveNotes() } }
                            .buttonStyle(.borderless).fontWeight(.semibold)
                    }
                }
            }
        }
    }
}
