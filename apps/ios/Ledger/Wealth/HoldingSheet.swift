import LedgerKit
import SwiftUI

/// Add or edit a holding of any kind (owners). Adding starts with the kind; gold and silver then
/// take metal, weight and cost (the photo follows metal and form), the other kinds their own
/// fields and a payment rule (`HoldingKindFields`). Numbers stay as typed and go up as decimal
/// strings. Validation, conversion, defaults and the server's refusals are `HoldingDraft`'s;
/// Close (with a confirmation) is offered when editing.
struct HoldingSheet: View {
    let model: InvestmentsModel
    let profileCode: String
    let canEdit: Bool
    let original: Holding?
    @State private var draft: HoldingDraft
    @State private var error: String?
    @State private var confirmingClose = false
    @Environment(BankCatalog.self) private var catalog: BankCatalog?
    @Environment(\.dismiss) private var dismiss

    init(model: InvestmentsModel, draft: HoldingDraft, original: Holding? = nil, profileCode: String, canEdit: Bool) {
        self.model = model
        self.profileCode = profileCode
        self.canEdit = canEdit
        self.original = original
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.kind == .metal {
                    Section {
                        HoldingPhoto(url: draft.imageURL(supabaseURL: catalog?.supabaseURL), label: draft.imageLabel,
                                     width: nil, height: 160, cornerRadius: Metrics.radiusLg)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if let error { ErrorSection(text: error) }
                if draft.canChangeKind {
                    Section {
                        Picker("Kind", selection: $draft.kind.animation()) {
                            ForEach(HoldingKind.addable) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                        }
                    } header: {
                        Text("What it is")
                    } footer: {
                        Text(draft.kind.explanation)
                    }
                }
                Section {
                    TextField(draft.namePlaceholder, text: $draft.name)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Name")
                } header: { Text("Name") }
                if draft.kind == .metal {
                    metalSection
                    weightSection
                    costSection
                } else {
                    HoldingKindFields(draft: $draft)
                }
                Section {
                    TextField("Optional", text: $draft.notes, axis: .vertical).lineLimit(1...4)
                } header: { Text("Notes") }
                if draft.isEditing, canEdit {
                    Section {
                        Button("Close holding", role: .destructive) { confirmingClose = true }
                    } footer: {
                        Text(InvestmentsModel.closeMessage)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetToolbar(isSaving: model.isSaving, saveLabel: draft.saveLabel, save: save, cancel: { dismiss() })
            }
            .confirmationDialog(original.map(InvestmentsModel.closeTitle) ?? "", isPresented: $confirmingClose,
                                titleVisibility: .visible) {
                Button("Close holding", role: .destructive, action: close)
            } message: {
                Text(InvestmentsModel.closeMessage)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private var costSection: some View {
        Section {
            HStack {
                Text("AED").foregroundStyle(Palette.muted)
                TextField("Optional", text: $draft.cost)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                    .accessibilityLabel("What you paid, in AED")
            }
            Toggle("Date bought", isOn: $draft.hasAcquiredOn.animation())
            if draft.hasAcquiredOn {
                DatePicker("Bought on", selection: acquiredOn, in: ...Date.now, displayedComponents: .date)
                    .environment(\.timeZone, LedgerDates.timeZone)
            }
        } header: {
            Text("What you paid")
        } footer: {
            Text("The total you paid, in AED. Gains are counted against it; leave it empty if you don't know.")
        }
    }

    private var metalSection: some View {
        Section {
            Picker("Metal", selection: $draft.metal.animation()) {
                ForEach(Metal.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.metal == .gold {
                Picker("Karat", selection: $draft.karat.animation()) {
                    ForEach(GoldKarat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if draft.asksFineness {
                    Picker("Fineness", selection: $draft.fineness) {
                        ForEach(GoldFineness.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                Picker("Purity", selection: $draft.purity) {
                    ForEach(SilverPurity.choices(including: draft.purity)) { Text($0.label).tag($0) }
                }
            }
            Picker("Form", selection: $draft.form.animation()) {
                ForEach(draft.formChoices) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Metal")
        } footer: {
            Text(draft.metal == .gold
                ? "Valued at the Dubai retail rate for its karat. 24K is priced for 999.9; a 999.5, 999 or 995 piece is valued in proportion."
                : "Valued at the Dubai retail silver rate, in proportion to its purity.")
        }
    }

    private var weightSection: some View {
        Section {
            HStack {
                TextField("e.g. 10", text: $draft.weight)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                    .accessibilityLabel("Weight in \(draft.unit.label)")
                Picker("Unit", selection: $draft.unit) {
                    ForEach(WeightUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        } header: {
            Text("Weight")
        } footer: {
            Text(draft.gramsPreview.map { "\($0). A tola is 11.6638 g." } ?? "In grams, kilograms or tola (11.6638 g).")
        }
    }

    /// The date picker edits a Dubai calendar day.
    private var acquiredOn: Binding<Date> {
        Binding(get: { draft.acquiredOn.startDate }, set: { draft.acquiredOn = CalendarDay(date: $0) })
    }

    private func save() {
        Task {
            if let problem = await model.save(draft, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }

    private func close() {
        guard let original else { return }
        Task {
            if let problem = await model.close(original, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}
