import LedgerKit
import SwiftUI

/// Update balance (owners): the balance the bank shows now, kept as typed and sent as a decimal
/// string. Validation and wording are `UpdateBalanceDraft`'s.
struct UpdateBalanceSheet: View {
    let model: CashModel
    let profileCode: String
    @State private var draft: UpdateBalanceDraft
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: CashModel, draft: UpdateBalanceDraft, profileCode: String) {
        self.model = model
        self.profileCode = profileCode
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ErrorSection(text: error) }
                Section {
                    HStack {
                        Text(draft.currency).foregroundStyle(Palette.muted)
                        TextField("0.00", text: $draft.amount)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focused)
                            .monospacedDigit()
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityLabel("Balance in \(draft.currency)")
                    }
                } header: {
                    Text(draft.accountTitle)
                } footer: {
                    Text("The balance your bank shows now, e.g. 28650.40. Use a minus sign if the account is overdrawn.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Update balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Save", save: save, cancel: { dismiss() }) }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private func save() {
        Task {
            if let problem = await model.updateBalance(draft, profileCode: profileCode) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// Add bank account (owners): bank, current or savings, the digits after the mask and a
/// nickname. Validation and the server's refusals are worded by `AddBankAccountDraft`.
struct AddBankAccountSheet: View {
    let model: CashModel
    let profileCode: String
    @State private var draft = AddBankAccountDraft()
    @State private var error: String?
    @Environment(BankCatalog.self) private var catalog: BankCatalog?
    @Environment(\.dismiss) private var dismiss

    private var banks: [BankInfo] { AddBankAccountDraft.bankChoices(catalog.map { Array($0.banks.values) } ?? []) }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ErrorSection(text: error) }
                Section {
                    Picker("Bank", selection: $draft.bankCode) {
                        Text("Choose").tag(String?.none)
                        ForEach(banks) { bank in Text(bank.name).tag(Optional(bank.bankCode)) }
                    }
                    Picker("Type", selection: $draft.kind) {
                        ForEach(BankAccountKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("e.g. 310001", text: $draft.accountRef)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                        .accessibilityLabel("Account number ends in")
                } header: {
                    Text("Account number ends in")
                } footer: {
                    Text("The 3 to 12 digits your bank's SMS show after the mask, e.g. 310001 in XXX310001. Alerts find the account by them.")
                }
                Section {
                    TextField("e.g. Salary account", text: $draft.nickname)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Nickname (optional)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Add bank account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Add", save: save, cancel: { dismiss() }) }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSaving)
        .task { await catalog?.refresh() }
    }

    private func save() {
        Task {
            if let problem = await model.addAccount(draft, profileCode: profileCode) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// The form's error, first so the keyboard never hides it.
struct ErrorSection: View {
    let text: String

    var body: some View {
        Section {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(Typography.rowMeta).foregroundStyle(Palette.danger)
        }
    }
}

struct SheetToolbar: ToolbarContent {
    let isSaving: Bool
    let saveLabel: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
            } else {
                Button(saveLabel, action: save).fontWeight(.semibold)
            }
        }
    }
}
