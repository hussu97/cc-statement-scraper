import LedgerKit
import SwiftUI

/// The owner's transaction sheet: which investment the payment went to, a picker to link it and
/// Unlink. A linked payment is saving, not spending. `TransactionLinkModel` decides and words it.
struct InvestmentLinkSection: View {
    let model: TransactionLinkModel

    var body: some View {
        Section {
            NavigationLink {
                InvestmentPicker(model: model)
            } label: {
                HStack {
                    Text(model.isLinked ? "Linked to" : "Link to investment").foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Text(model.statusText).foregroundStyle(model.isLinked ? Palette.ink : Palette.muted)
                    }
                }
            }
            .disabled(model.isSaving || (!model.canLink && !model.isLinked))
            if model.isLinked {
                Button("Unlink", role: .destructive) { Task { _ = await model.unlink() } }
                    .disabled(model.isSaving)
            }
        } header: {
            Text("Investment")
        } footer: {
            Text(model.canLink || model.isLinked ? TransactionLinkModel.footer : TransactionLinkModel.noAmountMessage)
        }
        .alert("Couldn't link it", isPresented: Binding(get: { model.errorMessage != nil },
                                                        set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The holdings by kind; picking one links the payment and goes back.
private struct InvestmentPicker: View {
    let model: TransactionLinkModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let message = model.choices.errorMessage, model.choices.value == nil {
                Text(message).foregroundStyle(Palette.danger)
            } else if model.choices.value == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let empty = model.noChoicesMessage { Text(empty).foregroundStyle(Palette.muted) }
            ForEach(model.groups) { group in
                Section(group.title) {
                    ForEach(group.holdings) { holding in
                        Button {
                            Task { if await model.link(holding) { dismiss() } }
                        } label: {
                            HStack {
                                Label(holding.name, systemImage: holding.kind.systemImage).foregroundStyle(Palette.ink)
                                Spacer()
                                if holding.holdingCode == model.linkedCode {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .disabled(model.isSaving)
                        .accessibilityAddTraits(holding.holdingCode == model.linkedCode ? .isSelected : [])
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("Link to investment")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadChoices() }
    }
}
