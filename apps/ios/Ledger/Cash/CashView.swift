import LedgerKit
import SwiftUI

/// Cash & accounts (Phase 2d): the bank accounts with the server's balances, Update balance and
/// Add bank account for owners, and the month's cash flow. Reached from Overview's cash tile.
struct CashView: View {
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
                BankAccountsCard(position: content.position, canEdit: canEdit) { account in
                    updating = UpdateBalanceDraft(account: account)
                }
                CashFlowCard(model: model, content: content, retry: reload)
            }
        }
        .ledgerNavigation("Cash & accounts")
        .navigationBarTitleDisplayMode(.inline)
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

/// The total and each account: logo, name, balance, how fresh, and Update balance for owners.
private struct BankAccountsCard: View {
    let position: CashPosition
    let canEdit: Bool
    let update: (BankAccountBalance) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Bank accounts")
            if position.accounts.isEmpty {
                Text(CashPosition.noAccountsMessage(canEdit: canEdit))
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            } else {
                total
                ForEach(position.accounts) { account in
                    Divider().overlay(Palette.border)
                    row(account)
                }
            }
        }
    }

    private var total: some View {
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

    private func row(_ account: BankAccountBalance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow(alignment: .center) {
                HStack(alignment: .center, spacing: 10) {
                    BankLogo(bankCode: account.bankCode, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(account.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            } trailing: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(account.balanceText)
                        .font(account.hasBalance ? Typography.amount : Typography.rowMeta)
                        .foregroundStyle(account.hasBalance ? Palette.ink : Palette.muted)
                        .moneyLine()
                    if let stale = account.staleLabel { Chip(label: stale, tone: .warn) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if let asOf = account.asOfText() {
                    Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                if canEdit {
                    Button { update(account) } label: {
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
