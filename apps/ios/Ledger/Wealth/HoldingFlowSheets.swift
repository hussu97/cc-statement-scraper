import LedgerKit
import SwiftUI

/// Add money in, money out or income to a holding (owners): the amount in the holding's
/// currency, optionally what it came to in AED, the day and a note. `FlowDraft` validates.
struct AddFlowSheet: View {
    let model: HoldingDetailModel
    let profileCode: String
    let canEdit: Bool
    @State private var draft: FlowDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: HoldingDetailModel, draft: FlowDraft, profileCode: String, canEdit: Bool) {
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
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(HoldingFlowKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(draft.kind.explanation)
                }
                Section {
                    HStack {
                        Text(draft.currency).foregroundStyle(Palette.muted)
                        TextField("Amount", text: $draft.amount)
                            .keyboardType(.decimalPad).monospacedDigit()
                            .accessibilityLabel("Amount in \(draft.currency)")
                    }
                    if draft.asksAed {
                        HStack {
                            Text("AED").foregroundStyle(Palette.muted)
                            TextField("Optional", text: $draft.amountAed)
                                .keyboardType(.decimalPad).monospacedDigit()
                                .accessibilityLabel("What it came to in AED")
                        }
                    }
                    DatePicker("On", selection: date, in: ...Date.now, displayedComponents: .date)
                        .environment(\.timeZone, LedgerDates.timeZone)
                } header: {
                    Text("Amount")
                } footer: {
                    if draft.asksAed { Text(draft.aedNote) }
                }
                Section {
                    TextField("Optional, e.g. Dividend", text: $draft.notes, axis: .vertical).lineLimit(1...3)
                } header: { Text("Note") } footer: {
                    Text("For a payment already in the ledger, link it from its transaction instead, so it isn't counted twice.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(draft.holdingName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Add", save: save, cancel: { dismiss() }) }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private var date: Binding<Date> {
        Binding(get: { draft.date.startDate }, set: { draft.date = CalendarDay(date: $0) })
    }

    private func save() {
        Task {
            if let problem = await model.addFlow(draft, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// Record a plan's or broker account's value, or a share's price per unit, as of a day (owners).
struct UpdateValueSheet: View {
    let model: HoldingDetailModel
    let profileCode: String
    let canEdit: Bool
    @State private var draft: ValueDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: HoldingDetailModel, draft: ValueDraft, profileCode: String, canEdit: Bool) {
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
                    HStack {
                        Text(draft.currency).foregroundStyle(Palette.muted)
                        TextField(draft.isUnitPrice ? "e.g. 4.10" : "e.g. 53800", text: $draft.amount)
                            .keyboardType(.decimalPad).monospacedDigit()
                            .accessibilityLabel(draft.fieldTitle)
                    }
                    DatePicker("As of", selection: asOf, in: ...Date.now, displayedComponents: .date)
                        .environment(\.timeZone, LedgerDates.timeZone)
                } header: {
                    Text(draft.fieldTitle)
                } footer: {
                    Text(draft.note)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Save", save: save, cancel: { dismiss() }) }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private var asOf: Binding<Date> {
        Binding(get: { draft.asOf.startDate }, set: { draft.asOf = CalendarDay(date: $0) })
    }

    private func save() {
        Task {
            if let problem = await model.recordValue(draft, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}
