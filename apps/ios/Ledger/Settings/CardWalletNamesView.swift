import LedgerKit
import SwiftUI

/// Settings → Card names for payment shortcut: each card of the ledger and the
/// name "Log Card Payment" matches it by (`cards.wallet_name`). Owners edit;
/// viewers see the names read-only. Decisions are in `CardWalletNamesModel`.
struct CardWalletNamesView: View {
    let profileCode: String
    let canEdit: Bool
    @State private var model: CardWalletNamesModel

    init(api: any LedgerAPI, profileCode: String, canEdit: Bool) {
        self.profileCode = profileCode
        self.canEdit = canEdit
        _model = State(initialValue: CardWalletNamesModel(api: api))
    }

    var body: some View {
        List {
            Section {
                switch model.state {
                case .idle, .loading(previous: nil):
                    ProgressView()
                case .failed(let message, previous: nil):
                    Text(message).foregroundStyle(Palette.danger)
                    Button("Try again") { Task { await model.load(profileCode: profileCode) } }
                default:
                    if model.isEmpty {
                        Text("This ledger has no cards yet. Cards appear here once a statement or SMS adds them.")
                            .foregroundStyle(Palette.muted)
                    }
                    ForEach(model.cards) { card in
                        CardNameRow(card: card, canEdit: canEdit, isSaving: model.saving == card.cardCode,
                                    error: model.errors[card.cardCode], saved: model.saved.contains(card.cardCode)) { name in
                            Task { await model.save(card, name: name) }
                        }
                    }
                }
            } footer: {
                Text(canEdit
                     ? CardWalletNamesModel.hint
                     : "Only the ledger's owners can change card names.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("Card names")
        .refreshable { await model.load(profileCode: profileCode) }
        .task(id: profileCode) { await model.load(profileCode: profileCode) }
    }
}

private struct CardNameRow: View {
    let card: LedgerCard
    let canEdit: Bool
    let isSaving: Bool
    let error: String?
    let saved: Bool
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BankLogo(bankCode: card.bankCode, size: 18)
                Text(card.label).font(Typography.rowTitle)
                Spacer()
                if isSaving {
                    ProgressView()
                } else if saved && error == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.positive)
                        .accessibilityLabel("Saved")
                }
            }
            if canEdit {
                HStack {
                    TextField("Name on the card", text: $text)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { save(text) }
                    if text != (card.walletName ?? "") {
                        Button("Save") { save(text) }
                            .buttonStyle(.bordered).tint(Palette.accent)
                            .disabled(isSaving)
                    }
                }
                .font(Typography.rowMeta)
            } else {
                Text(card.walletName ?? "No name set")
                    .font(Typography.rowMeta)
                    .foregroundStyle(card.walletName == nil ? Palette.muted : Palette.ink)
            }
            if let error {
                Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
            }
        }
        .padding(.vertical, 4)
        .onAppear { text = card.walletName ?? "" }
        .onChange(of: card.walletName) { _, name in text = name ?? "" }
    }
}
