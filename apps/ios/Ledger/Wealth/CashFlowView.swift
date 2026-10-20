import LedgerKit
import SwiftUI

/// Wealth's Cash flow tab: a month's money in and out by group with the server's net (a month
/// before the bank accounts' first evidence reads as partial, not a loss), the last months'
/// nets, and an account filter.
struct CashFlowView: View {
    let model: CashModel
    let profileCode: String

    var body: some View {
        Page {
            if !model.accountChoices.isEmpty {
                accountFilter.padding(.top, 8)
            }
            StateContainer(state: model.state, retry: reload) { content in
                CashFlowCard(model: model, content: content, retry: reload)
            }
        }
        .rootNavigation("Cash flow")
        .task { await model.loadIfNeeded(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode) }
    }

    private var accountFilter: some View {
        Menu {
            Picker("Account", selection: Binding(
                get: { model.accountFilter },
                set: { code in Task { await model.setAccountFilter(code, profileCode: profileCode) } })) {
                Text("All accounts").tag(String?.none)
                ForEach(model.accountChoices) { account in
                    Text("\(account.bankCode) · \(account.title)").tag(Optional(account.accountCode))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "building.columns").foregroundStyle(Palette.muted)
                Text(model.accountFilterLabel).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.tapMin)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
        }
        .accessibilityLabel("Account")
        .accessibilityValue(model.accountFilterLabel)
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}
