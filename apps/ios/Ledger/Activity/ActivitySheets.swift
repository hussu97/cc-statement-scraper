import LedgerKit
import SwiftUI

/// The transaction sheet (IOS-18): the category, searchable, with "None" to
/// clear a manual choice and merchant-wide by default; exclude from spend; and
/// notes. `TransactionEditor` decides; owners only (viewers never open it).
struct CategorySheet: View {
    @State private var editor: TransactionEditor
    @Environment(\.dismiss) private var dismiss

    init(transaction: LedgerTransaction, categories: [FilterMeta.CategoryOption], profileCode: String,
         target: any TransactionEditing) {
        _editor = State(initialValue: TransactionEditor(transaction: transaction, categories: categories,
                                                        profileCode: profileCode, target: target))
    }

    var body: some View {
        NavigationStack {
            List {
                if editor.showsDetails { Section { summary } }
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
                }
            }
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transaction.title).font(Typography.rowTitle)
            Text("\(transaction.amountLabel) · \(LedgerDates.dayLabel(transaction.txnDate))")
                .font(Typography.rowMeta).monospacedDigit().foregroundStyle(Palette.muted)
            BankCardLabel(bankCode: transaction.bankCode, label: transaction.cardSuffix, size: 18,
                          font: Typography.rowMeta)
            if let peer = transaction.transferPeer {
                TransferPeerLabel(peer: peer, size: 18, font: Typography.rowMeta)
            }
        }
    }

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
