import LedgerKit
import SwiftUI

/// A deposit or withdrawal on an account no SMS or statement reaches (a broker's cash; owners):
/// the direction, amount, day and an optional description. `AccountEntryDraft` validates.
struct AccountEntrySheet: View {
    let model: NotesModel
    let profileCode: String
    let canEdit: Bool
    @State private var draft: AccountEntryDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: NotesModel, draft: AccountEntryDraft, profileCode: String, canEdit: Bool) {
        self.model = model
        self.profileCode = profileCode
        self.canEdit = canEdit
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ErrorSection(text: error) }
                Section {
                    Picker("Direction", selection: $draft.direction) {
                        ForEach(AccountEntryDraft.Direction.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("\(draft.accountTitle): \(AccountEntryDraft.explanation)")
                }
                Section {
                    HStack {
                        Text(draft.currency).foregroundStyle(Palette.muted)
                        TextField("25000", text: $draft.amount)
                            .keyboardType(.decimalPad).monospacedDigit()
                            .accessibilityLabel(draft.amountLabel)
                    }
                    DatePicker("On", selection: date, in: ...Date.now, displayedComponents: .date)
                        .environment(\.timeZone, LedgerDates.timeZone)
                } header: {
                    Text("Amount")
                } footer: {
                    Text("The day it reached (or left) the account.")
                }
                Section {
                    TextField("Optional, e.g. Transfer from Wio", text: $draft.description)
                } header: { Text("Description") }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(AccountEntryDraft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Add", save: save, cancel: { dismiss() }) }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private var date: Binding<Date> {
        Binding(get: { draft.date.startDate }, set: { draft.date = CalendarDay(date: $0) })
    }

    private func save() {
        Task {
            if let problem = await model.addEntry(draft, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}
