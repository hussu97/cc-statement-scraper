import LedgerKit
import SwiftUI

/// A savings account's holding screen: how it is valued, its stated rate, the bank account it is
/// valued at (opening that account's screen) and, for owners, Show as cash instead (closes the
/// holding; the account counts as cash again). What shows is `HoldingActions`'.
struct SavingsAccountSection: View {
    let holding: Holding
    let investments: InvestmentsModel
    let profileCode: String
    let canEdit: Bool
    @State private var confirming = false
    @State private var error: String?
    @Environment(CashModel.self) private var cash
    @Environment(AccountLedgers.self) private var ledgers

    var body: some View {
        let actions = holding.actions(canEdit: canEdit)
        Section {
            if actions.opensBankAccount {
                if let account = holding.bankAccount(in: cash.state.value?.position) {
                    NavigationLink {
                        AccountLedgerView(model: ledgers.model(for: account.accountCode), profileCode: profileCode,
                                          canEdit: canEdit)
                    } label: {
                        HStack(spacing: 10) {
                            BankLogo(bankCode: account.bankCode, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                                Text(account.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 8)
                            Text(account.balanceText).font(Typography.amount).foregroundStyle(Palette.ink).moneyLine()
                        }
                    }
                    .accessibilityHint("Opens the bank account's transactions")
                } else if let message = cash.state.errorMessage {
                    Text(message).font(Typography.rowMeta).foregroundStyle(Palette.danger)
                } else if cash.state.value == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            if let rate = holding.savingsRateText {
                LabeledContent("Stated rate", value: rate)
            }
            if actions.stopShowing {
                Button(SavingsAccountText.stopShowing, role: .destructive) { confirming = true }
                    .disabled(investments.isSaving)
            }
        } header: {
            Text(SavingsAccountText.openAccount)
        } footer: {
            if let note = holding.valuedByAccountNote { Text(note) }
        }
        .confirmationDialog(SavingsAccountText.stopTitle(holding), isPresented: $confirming, titleVisibility: .visible) {
            Button(SavingsAccountText.stopShowing, role: .destructive, action: stop)
        } message: {
            Text(SavingsAccountText.stopMessage)
        }
        .alert("Couldn't change it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func stop() {
        Task {
            if let problem = await investments.close(holding, profileCode: profileCode, canEdit: canEdit) { error = problem }
        }
    }
}

/// The bank account screen's line about Investments: "Shown under Investments" opening the
/// holding, or the owner's "Show under Investments". Nothing for an account that can't be shown.
struct AccountInvestmentRow: View {
    let account: BankAccountBalance
    let canEdit: Bool
    let open: (String) -> Void
    let show: () -> Void

    var body: some View {
        if let code = account.investmentHoldingCode {
            Button { open(code) } label: {
                HStack(spacing: 10) {
                    Image(systemName: HoldingKind.savingsAccount.systemImage).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SavingsAccountText.shownTitle).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(SavingsAccountText.shownNote).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                }
                .frame(minHeight: Metrics.tapMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the investment")
        } else if account.canShowAsInvestment(canEdit: canEdit) {
            Button(action: show) {
                Label(TrackAccountDraft.title, systemImage: "chart.line.uptrend.xyaxis")
            }
            .font(Typography.rowMeta).tint(Palette.accent)
            .frame(minHeight: Metrics.tapMin)
        }
    }
}

/// Show under Investments (owners): an optional stated interest rate, then
/// `track_account_as_investment`. Validation and wording are `TrackAccountDraft`'s.
struct TrackAccountSheet: View {
    let model: InvestmentsModel
    let profileCode: String
    let canEdit: Bool
    @State private var draft: TrackAccountDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: InvestmentsModel, draft: TrackAccountDraft, profileCode: String, canEdit: Bool) {
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
                    Text(TrackAccountDraft.explanation).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                } header: {
                    Text(draft.accountTitle)
                }
                Section {
                    HStack {
                        Text(TrackAccountDraft.rateLabel).foregroundStyle(Palette.muted)
                        TextField(TrackAccountDraft.ratePlaceholder, text: $draft.ratePct)
                            .keyboardType(.decimalPad).monospacedDigit().multilineTextAlignment(.trailing)
                            .accessibilityLabel("Interest rate a year, percent")
                        Text("%").foregroundStyle(Palette.muted)
                    }
                } footer: {
                    Text(TrackAccountDraft.rateNote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle(TrackAccountDraft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetToolbar(isSaving: model.isSaving, saveLabel: "Show", save: save, cancel: { dismiss() }) }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isSaving)
    }

    private func save() {
        Task {
            if let problem = await model.track(draft, profileCode: profileCode, canEdit: canEdit) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}
