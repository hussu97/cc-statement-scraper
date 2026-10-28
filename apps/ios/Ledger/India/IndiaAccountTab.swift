import LedgerKit
import SwiftUI

/// India's Kite or Coin tab: that account's portfolio, the same screen Investments opens for a
/// broker account (`AccountLedgerView` with its portfolio), in the account's rupees. Which account
/// is `IndiaModel.account(for:)`'s.
struct IndiaAccountTab: View {
    let model: IndiaModel
    let tab: LedgerTab
    let profileCode: String
    let canEdit: Bool
    @Environment(AccountLedgers.self) private var ledgers

    var body: some View {
        if let account = model.account(for: tab) {
            AccountLedgerView(model: ledgers.model(for: account.accountCode), profileCode: profileCode,
                              canEdit: canEdit, showsPortfolio: true, isTabRoot: true)
        } else {
            Page {
                StateContainer(state: model.state, retry: reload) { _ in
                    EmptyCard(systemImage: tab.systemImage, message: IndiaText.unavailableMessage)
                }
                .padding(.top, 8)
            }
            .rootNavigation(tab.title)
            .task { await model.loadIfNeeded(profileCode: profileCode) }
            .refreshable { await model.load(profileCode: profileCode) }
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}
