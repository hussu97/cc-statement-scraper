import LedgerKit
import SwiftUI

/// Wealth's Accounts tab: the bank accounts with the server's balances and their total, each
/// opening its ledger; Update balance and Add bank account for owners.
struct AccountsView: View {
    let model: CashModel
    let profileCode: String
    let canEdit: Bool
    @State private var updating: UpdateBalanceDraft?
    @State private var adding = false

    var body: some View {
        Page {
            if let notice = model.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { content in
                Card {
                    SectionHeader(title: "Bank accounts")
                    if content.position.accounts.isEmpty {
                        Text(CashPosition.noAccountsMessage(canEdit: canEdit))
                            .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    } else {
                        CashTotal(position: content.position)
                        ForEach(content.position.accounts) { account in
                            Divider().overlay(Palette.border)
                            BankAccountRow(account: account, profileCode: profileCode, canEdit: canEdit) {
                                updating = UpdateBalanceDraft(account: account)
                            }
                        }
                    }
                }
                if !content.position.accounts.isEmpty {
                    Text("Open an account to see its transactions with the balance after each one.")
                        .font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(.top, 8)
        }
        .rootNavigation("Accounts")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add bank account")
                }
            }
        }
        .sheet(item: $updating) { draft in
            UpdateBalanceSheet(model: model, draft: draft, profileCode: profileCode)
        }
        .sheet(isPresented: $adding) {
            AddBankAccountSheet(model: model, profileCode: profileCode)
        }
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
        .onDisappear { model.notice = nil }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

/// The AED total across the bank accounts, how fresh it is and what it can't vouch for.
struct CashTotal: View {
    let position: CashPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(Typography.rowMeta).foregroundStyle(Palette.muted)
                Spacer()
                Text(position.totalText).font(Typography.amountLarge).foregroundStyle(Palette.ink).moneyLine()
            }
            .accessibilityElement(children: .combine)
            if let asOf = position.asOfText() {
                Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
            }
            ForEach(position.caveats, id: \.self) { caveat in
                Text(caveat).font(Typography.caption)
                    .foregroundStyle(position.caveatTone == .warn ? Palette.warn : Palette.muted)
            }
        }
    }
}

/// One bank account: logo, name, balance and how fresh, opening its ledger; an owner's Update
/// balance under it when `update` is set.
struct BankAccountRow: View {
    let account: BankAccountBalance
    let profileCode: String
    let canEdit: Bool
    var update: (() -> Void)?
    @Environment(AccountLedgers.self) private var ledgers

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                AccountLedgerView(model: ledgers.model(for: account.accountCode), profileCode: profileCode,
                                  canEdit: canEdit)
            } label: {
                AdaptiveRow(alignment: .center) {
                    HStack(alignment: .center, spacing: 10) {
                        BankLogo(bankCode: account.bankCode, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                            Text(account.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                        }
                    }
                } trailing: {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(account.balanceText)
                                .font(account.hasBalance ? Typography.amount : Typography.rowMeta)
                                .foregroundStyle(account.hasBalance ? Palette.ink : Palette.muted)
                                .moneyLine()
                            if let stale = account.staleLabel { Chip(label: stale, tone: .warn) }
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the account's transactions")
            if account.asOfText() != nil || (canEdit && update != nil) {
                HStack(alignment: .firstTextBaseline) {
                    if let asOf = account.asOfText() {
                        Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 8)
                    if canEdit, let update {
                        Button(action: update) {
                            Text(account.updateLabel)
                                .font(Typography.rowMeta).foregroundStyle(Palette.accent)
                                .frame(minHeight: Metrics.tapMin)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Update balance of \(account.title)")
                    }
                }
            }
        }
    }
}
