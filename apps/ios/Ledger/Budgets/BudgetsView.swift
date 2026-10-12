import LedgerKit
import SwiftUI

/// Budgets tab: the month's budgets as the server tracks them (`budget_status`),
/// the ones not active that month, and create / edit / delete for owners.
/// Every figure and rule comes from `BudgetsModel` (LedgerKit).
struct BudgetsView: View {
    let model: BudgetsModel
    let month: MonthSelection
    let profileCode: String
    let canEdit: Bool
    @State private var editing: BudgetDraft?
    @State private var deleting: Deletion?

    struct Deletion: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private var phase: BudgetMonthPhase { BudgetMonthPhase(month: month.month) }

    var body: some View {
        Page {
            MonthSwitcher(month: month).padding(.top, 8)
            if !canEdit {
                Text("You're a viewer on this ledger. Only its owners can change budgets.")
                    .font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            if let notice = model.notice {
                Text(notice.text).font(Typography.caption)
                    .foregroundStyle(notice.isError ? Palette.danger : Palette.positive)
            }
            StateContainer(state: model.state, retry: reload) { content in
                if content.status.isEmpty {
                    EmptyBudgetsCard(title: content.emptyTitle(month: month.month), detail: content.emptyDetail,
                                     canCreate: canEdit && content.hasNoBudgets, create: create)
                }
                ForEach(content.status) { row in
                    BudgetStatusCard(row: row, phase: phase, canEdit: canEdit && content.draft(for: row.budgetCode) != nil,
                                     edit: { editing = content.draft(for: row.budgetCode) },
                                     delete: { deleting = Deletion(code: row.budgetCode, name: row.title) })
                }
                if !content.inactive.isEmpty {
                    InactiveBudgetsCard(content: content, month: month.month, canEdit: canEdit,
                                        edit: { editing = BudgetDraft(budget: $0) },
                                        delete: { deleting = Deletion(code: $0.budgetCode, name: content.name(of: $0)) })
                }
            }
        }
        .ledgerNavigation("Budgets")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: create) { Image(systemName: "plus") }
                        .accessibilityLabel("New budget")
                }
            }
        }
        .task(id: month.requestMonth) {
            await model.loadIfNeeded(profileCode: profileCode, month: month.requestMonth)
        }
        .refreshable { await model.load(profileCode: profileCode, month: month.requestMonth) }
        .sheet(item: $editing) { draft in
            BudgetEditSheet(model: model, draft: draft, profileCode: profileCode)
        }
        .confirmationDialog("Delete this budget?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete budget", role: .destructive) {
                Task { await model.delete(budgetCode: item.code, profileCode: profileCode) }
            }
            Button("Keep it", role: .cancel) {}
        } message: { item in
            Text(BudgetsModel.deleteMessage(name: item.name))
        }
    }

    private func create() { editing = BudgetDraft.new(month: month.month) }
    private func reload() { Task { await model.load(profileCode: profileCode, month: month.requestMonth) } }
}

/// One `budget_status` row: spent of limit, the meter, share used and pace.
private struct BudgetStatusCard: View {
    let row: BudgetStatus
    let phase: BudgetMonthPhase
    let canEdit: Bool
    let edit: () -> Void
    let delete: () -> Void

    private var tone: Tone { row.tone(isCurrentMonth: phase == .current) }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                if let bank = row.bankCode, row.categoryCode == nil {
                    BankLogo(bankCode: bank, size: 18)
                } else if row.categoryCode == nil {
                    Circle().fill(Palette.ink).frame(width: 8, height: 8)
                } else {
                    CategoryDot(token: row.colorToken, size: 10)
                }
                Text(row.title).font(Typography.cardTitle).foregroundStyle(Palette.ink).lineLimit(2)
                if row.isOver { Chip(label: "Over", tone: .danger) }
                Spacer()
                if canEdit {
                    Menu {
                        Button("Edit", systemImage: "pencil", action: edit)
                        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Palette.muted)
                            .frame(width: Metrics.tapMin, height: Metrics.tapMin)
                    }
                    .accessibilityLabel("Actions for \(row.title)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MoneyFormat.aed(row.spentAed)).font(Typography.amountLarge).foregroundStyle(Palette.ink)
                Text("of \(MoneyFormat.aed(row.budgetAed))").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
            .moneyLine()
            ProgressView(value: row.progressFraction).tint(tone.color)
                .accessibilityLabel(row.meterAccessibilityLabel)
            HStack {
                Text(row.usedLabel).font(Typography.caption.weight(.semibold)).foregroundStyle(tone.color)
                Spacer()
                Text(row.paceLabel(phase)).font(Typography.caption)
                    .foregroundStyle(row.isOverPace(phase) ? Palette.warn : Palette.muted)
            }
            .monospacedDigit()
        }
    }
}

/// Budgets that don't apply to the month on screen, and why.
private struct InactiveBudgetsCard: View {
    let content: BudgetsModel.Content
    let month: CalendarDay
    let canEdit: Bool
    let edit: (Budget) -> Void
    let delete: (Budget) -> Void

    var body: some View {
        Card {
            SectionHeader(title: "Not active in \(LedgerDates.monthTitle(month))")
            ForEach(content.inactive) { budget in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if budget.isTotal {
                            Circle().fill(Palette.ink).frame(width: 8, height: 8)
                        } else {
                            CategoryDot(token: content.colorToken(of: budget))
                        }
                        if let bank = content.bankCode(of: budget) { BankLogo(bankCode: bank, size: 16) }
                        Text(content.name(of: budget)).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(MoneyFormat.aed(budget.amountAed)).font(Typography.amount).foregroundStyle(Palette.ink2)
                    }
                    HStack {
                        Chip(label: budget.inactiveLabel(month: month))
                        Spacer()
                        if canEdit {
                            Button("Edit") { edit(budget) }.frame(minHeight: Metrics.tapMin)
                            Button("Delete", role: .destructive) { delete(budget) }.frame(minHeight: Metrics.tapMin)
                        }
                    }
                    .font(Typography.rowMeta)
                    .buttonStyle(.borderless)
                }
                if budget.id != content.inactive.last?.id { Divider().overlay(Palette.border) }
            }
        }
    }
}

private struct EmptyBudgetsCard: View {
    let title: String
    let detail: String
    let canCreate: Bool
    let create: () -> Void

    var body: some View {
        Card {
            Label(title, systemImage: "target").font(Typography.cardTitle).foregroundStyle(Palette.ink)
            Text(detail).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            if canCreate {
                Button(action: create) {
                    Label("Create a budget", systemImage: "plus").frame(minHeight: Metrics.tapMin)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
        }
    }
}
