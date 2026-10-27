import LedgerKit
import SwiftUI

/// An account's money like a bank statement: its balance and Update balance, Add a deposit or
/// withdrawal (owners), the live notes paid from it, the last 90 days of balances, then a month of
/// rows with their flow and the balance after each, under the month's opening, in, out and
/// closing. Any account shows this; a synced broker account shows it under Transactions.
struct AccountTransactions: View {
    let model: AccountLedgerModel
    let balance: BankAccountBalance?
    let canEdit: Bool
    /// The live notes paid from this account (empty on a synced broker account, which shows its own).
    let notes: [NoteListRow]
    let update: () -> Void
    let addEntry: () -> Void
    let openRow: (AccountLedgerRow) -> Void
    let openNote: (String) -> Void
    let reload: () -> Void

    var body: some View {
        BalanceHeader(account: balance, ledger: model.state.value?.account, canEdit: canEdit, update: update)
        if canEdit, balance != nil {
            Button(action: addEntry) { Label("Add a deposit or withdrawal", systemImage: "plus.circle") }
                .font(Typography.rowMeta).tint(Palette.accent)
                .frame(minHeight: Metrics.tapMin)
        }
        if !notes.isEmpty {
            NotesCard(rows: notes, trailing: "Paid from this account", open: openNote)
        }
        BalanceChartCard(series: model.series, currency: model.state.value?.account.currency ?? balance?.currency ?? "AED")
        MonthSwitcher(month: model.month)
        StateContainer(state: model.state, retry: reload) { ledger in
            PeriodCard(ledger: ledger)
            if ledger.rows.isEmpty {
                EmptyCard(systemImage: "tray", message: model.emptyMessage)
            } else {
                Card {
                    ForEach(model.sections) { section in
                        Text(section.title.uppercased())
                            .font(Typography.caption).tracking(1).foregroundStyle(Palette.muted)
                        ForEach(section.rows) { row in
                            Button { openRow(row) } label: { LedgerRowView(row: row, currency: ledger.account.currency) }
                                .buttonStyle(.plain)
                            if row.id != section.rows.last?.id { Divider().overlay(Palette.border) }
                        }
                    }
                }
                Text(AccountLedger.fileHint).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// The account, its balance now and how fresh it is, and an owner's Update balance.
private struct BalanceHeader: View {
    let account: BankAccountBalance?
    let ledger: AccountLedger.Account?
    let canEdit: Bool
    let update: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let bank = account?.bankCode ?? ledger?.bankCode {
                HStack(spacing: 10) {
                    BankLogo(bankCode: bank, size: 28)
                    Text(account?.detail ?? ledger?.detail ?? bank).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                }
            }
            if let account {
                Text(account.balanceText)
                    .font(account.hasBalance ? Typography.display.monospacedDigit() : Typography.rowTitle)
                    .foregroundStyle(account.hasBalance ? Palette.ink : Palette.muted)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let asOf = account.asOfText() {
                        Text(asOf).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    if let stale = account.staleLabel { Chip(label: stale, tone: .warn) }
                    Spacer(minLength: 8)
                    if canEdit {
                        Button(account.updateLabel, action: update)
                            .font(Typography.rowMeta).tint(Palette.accent)
                            .frame(minHeight: Metrics.tapMin)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The month's opening balance, money in and out, and closing balance.
private struct PeriodCard: View {
    let ledger: AccountLedger

    var body: some View {
        Card {
            SectionHeader(title: "This period", trailing: LedgerDates.monthTitle(ledger.from))
            ForEach(ledger.summaryLines) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(line.text).font(Typography.amount)
                        .foregroundStyle(line.tone == .positive ? Palette.positive : Palette.ink)
                        .moneyLine()
                }
                .accessibilityElement(children: .combine)
            }
            if let note = ledger.unpricedNote {
                Text(note).font(Typography.caption).foregroundStyle(Palette.warn)
            }
        }
    }
}

/// A ledger row: category dot, title, caption and flow chip; the signed amount and the balance after.
private struct LedgerRowView: View {
    let row: AccountLedgerRow
    let currency: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryDot(token: row.categoryColor, size: 10).padding(.top, 6)
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    if let caption = row.caption {
                        Text(caption).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    if let flow = row.flowLabel { Chip(label: flow, tone: row.flowTone) }
                }
            } trailing: {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row.amountText(currency: currency)).font(Typography.amount).moneyLine()
                        .foregroundStyle(row.isCredit ? Palette.positive : Palette.ink)
                    if let balance = row.balanceText(currency: currency) {
                        Text(balance).font(Typography.caption).foregroundStyle(Palette.muted).moneyLine()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
