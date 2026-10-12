import LedgerKit
import SwiftUI

/// New / edit budget: every card or one, all spending or one category, a monthly
/// amount (kept as typed, sent as a decimal string), the start month and an
/// optional end.
/// Validation and wording are `BudgetDraft`'s.
struct BudgetEditSheet: View {
    let model: BudgetsModel
    let profileCode: String
    @State private var draft: BudgetDraft
    @State private var error: String?
    @FocusState private var amountFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: BudgetsModel, draft: BudgetDraft, profileCode: String) {
        self.model = model
        self.profileCode = profileCode
        _draft = State(initialValue: draft)
    }

    private var content: BudgetsModel.Content? { model.state.value }

    var body: some View {
        NavigationStack {
            Form {
                // First, so the keyboard never hides it.
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Typography.rowMeta).foregroundStyle(Palette.danger)
                    }
                }
                Section {
                    Picker("Card", selection: $draft.accountCode) {
                        Text("All cards").tag(String?.none)
                        ForEach(content?.cardChoices(keeping: draft.accountCode) ?? []) { choice in
                            Text(choice.label).tag(Optional(choice.accountCode))
                        }
                    }
                } footer: {
                    if content?.accountsFailed == true {
                        Text("Couldn't load cards; you can still budget every card.")
                    } else {
                        Text("Optional: count only one card's spending.")
                    }
                }

                Section {
                    Picker("Category", selection: $draft.categoryCode) {
                        Text("All spending").tag(String?.none)
                        ForEach(content?.categoryChoices(keeping: draft.categoryCode) ?? []) { choice in
                            Text(choice.depth > 0 ? "    \(choice.name)" : choice.name).tag(Optional(choice.categoryCode))
                        }
                    }
                } footer: {
                    if content?.categoriesFailed == true {
                        Text("Couldn't load categories; you can still budget all spending.")
                    }
                }

                Section {
                    HStack {
                        Text("AED").foregroundStyle(Palette.muted)
                        TextField("0.00", text: $draft.amount)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .monospacedDigit()
                            .accessibilityLabel("Monthly amount in AED")
                    }
                } header: {
                    Text("Monthly amount")
                } footer: {
                    Text("For example 1500 or 1500.50")
                }

                Section {
                    Picker("Starts", selection: Binding(get: { draft.effectiveFrom }, set: { draft.setStart($0) })) {
                        ForEach(draft.startChoices(), id: \.self) { Text(LedgerDates.monthTitle($0)).tag($0) }
                    }
                    Picker("Ends", selection: $draft.effectiveTo) {
                        Text("No end").tag(CalendarDay?.none)
                        ForEach(draft.endChoices(), id: \.self) { Text(LedgerDates.monthTitle($0)).tag(Optional($0)) }
                    }
                } footer: {
                    Text("A monthly limit for all spending or one category, on every card or one. It ends after the last month you pick.")
                }

            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button(draft.saveLabel, action: save).fontWeight(.semibold)
                    }
                }
            }
            .onAppear { if draft.isNew { amountFocused = true } }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private func save() {
        Task {
            if let problem = await model.save(draft, profileCode: profileCode) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}
