import LedgerKit
import SwiftUI

/// One bank account (Wealth mode). Any account reads like a bank statement
/// (`AccountTransactions`): its balance, the last 90 days, a month of rows; a row opens the
/// transaction sheet, where an owner files a transfer. Opened from Accounts, a synced broker account
/// (Swissquote, Zerodha) reads the same, without its notes or holdings. Opened from Investments
/// (`showsPortfolio`), it leads with its three numbers and the value over time, then offers
/// Portfolio (its live notes and other holdings), Transactions (the statement) and Past notes. Every figure is the server's; what
/// shows is LedgerKit's (`BrokerSection`, `BrokerPortfolioPresentation`).
struct AccountLedgerView: View {
    let model: AccountLedgerModel
    let profileCode: String
    let canEdit: Bool
    /// Investments' broker row: the portfolio, not only the statement.
    var showsPortfolio = false
    /// A tab's root (India's Kite and Coin): a large title and the mode menu.
    var isTabRoot = false
    @Environment(CashModel.self) private var cash
    @Environment(NotesModel.self) private var notes
    @Environment(InvestmentsModel.self) private var investments
    @State private var opened: LedgerTransaction?
    @State private var updating: UpdateBalanceDraft?
    @State private var entering: AccountEntryDraft?
    @State private var route: AccountRoute?
    @State private var tab: BrokerTab = .portfolio

    /// The account's balance as Accounts lists it (`cash_position`).
    private var balance: BankAccountBalance? {
        cash.state.value?.position.accounts.first { $0.accountCode == model.accountCode }
    }

    var body: some View {
        let section = model.brokerSection(bankCode: balance?.bankCode ?? model.state.value?.account.bankCode)
        Page {
            if let notice = notes.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Typography.rowMeta)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
                    .padding(.top, 8)
            }
            if !showsPortfolio {
                transactions(isBroker: section.isBroker).padding(.top, 8)
            } else if case .loaded(let p) = section {
                BrokerSummaryCard(p: p).padding(.top, 8)
                BrokerValueChartCard(chart: p.chart)
                Picker("Show", selection: $tab) {
                    ForEach(p.tabs) { Text(p.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                switch p.tabs.contains(tab) ? tab : .portfolio {
                case .portfolio: BrokerPortfolioTab(p: p) { route = $0 }
                case .transactions: transactions(isBroker: true)
                case .pastNotes: BrokerPastNotesTab(p: p) { route = $0 }
                }
            } else {
                BrokerPortfolioStatus(section: section, retry: reload).padding(.top, 8)
                transactions(isBroker: section.isBroker)
            }
        }
        .ledgerNavigation(model.state.value?.account.title ?? balance?.title ?? "Account")
        .navigationBarTitleDisplayMode(isTabRoot ? .automatic : .inline)
        .toolbar {
            if isTabRoot { ToolbarItem(placement: .principal) { ModeMenu() } }
        }
        .task(id: model.month.month) { await model.loadIfNeeded(profileCode: profileCode) }
        .task { await cash.loadIfNeeded(profileCode: profileCode) }
        .task { await notes.loadIfNeeded(profileCode: profileCode) }
        .refreshable {
            async let a: Void = model.load(profileCode: profileCode)
            async let b: Void = notes.load(profileCode: profileCode)
            _ = await (a, b)
        }
        .onDisappear { notes.notice = nil }
        .sheet(item: $entering) { draft in
            AccountEntrySheet(model: notes, draft: draft, profileCode: profileCode, canEdit: canEdit)
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .note(let code):
                NoteDetailView(notes: notes, holdingCode: code, profileCode: profileCode, canEdit: canEdit)
            case .holding(let code):
                HoldingDetailView(investments: investments, holdingCode: code, profileCode: profileCode, canEdit: canEdit)
            }
        }
        .sheet(item: $opened) { txn in
            if canEdit {
                CategorySheet(transaction: txn, categories: model.categories, profileCode: profileCode,
                              target: model, detail: model.detail(for: txn, profileCode: profileCode))
            } else {
                TransactionDetailSheet(model: model.detail(for: txn, profileCode: profileCode))
            }
        }
        .sheet(item: $updating) { draft in
            UpdateBalanceSheet(model: cash, draft: draft, profileCode: profileCode)
        }
        .alert("Couldn't open it", isPresented: Binding(get: { model.errorMessage != nil },
                                                        set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The statement; a broker account's notes are its portfolio's, not listed here.
    private func transactions(isBroker: Bool) -> some View {
        AccountTransactions(
            model: model, balance: balance, canEdit: canEdit,
            notes: isBroker ? [] : notes.liveRows(fundingAccount: model.accountCode, excluding: model.brokerHoldings) ?? [],
            update: { if let balance { updating = UpdateBalanceDraft(account: balance) } },
            addEntry: { if let balance { entering = notes.newEntry(for: balance) } },
            openRow: open,
            openNote: { route = .note($0) },
            reload: reload)
    }

    private func open(_ row: AccountLedgerRow) {
        Task { opened = await model.transaction(row.txnCode, profileCode: profileCode) }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}
