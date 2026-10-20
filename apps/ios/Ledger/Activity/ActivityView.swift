import LedgerKit
import SwiftUI

struct ActivityView: View {
    @Bindable var model: ActivityModel
    let months: MonthRange
    let profileCode: String
    /// Owners recategorise; viewers and view-only ledgers just read.
    let canEdit: Bool
    /// Hands over the filters or transaction another screen opened Activity with.
    var tabs: TabRouter?
    /// The open transaction: owners get the edit sheet, everyone else the read-only one.
    @State private var opened: LedgerTransaction?
    @State private var showFilters = false

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .rootNavigation("Activity")
        .searchable(text: $model.query.search, prompt: "Merchant or description")
        .onSubmit(of: .search) { reload() }
        .task(id: model.query.search) {
            // Debounce typing; the model drops superseded responses.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.loadIfNeeded(profileCode: profileCode)
        }
        .toolbar {
            // Bulk select (PAR-11): owners only; the bar below acts on the ticked rows.
            if model.selection.isSelecting || model.offersSelection(canEdit: canEdit) {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.selection.isSelecting ? "Done" : "Select") {
                        model.selection.setSelecting(!model.selection.isSelecting)
                    }
                    .fontWeight(model.selection.isSelecting ? .semibold : .regular)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: model.query.hasFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(model.query.hasFilters ? "Filters, \(model.query.filterCount) active" : "Filters")
            }
        }
        .refreshable { await model.load(profileCode: profileCode) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.selection.isSelecting && canEdit {
                ActivityBulkBar(model: model, profileCode: profileCode)
            }
        }
        // The bar's figures follow the selection (the model drops superseded answers).
        .task(id: model.selection.selection(for: model.listedQuery)) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.loadSelectionSummary(profileCode: profileCode)
        }
        // TabRouter.openActivity / openTransaction (Overview, Insights, ledger://uncategorised).
        // Keyed on the request count, not the preset: taking it must not cancel this task.
        .task(id: tabs?.activityPresetRequest) {
            if let preset = tabs?.takeActivityPreset() {
                await model.show(preset, profileCode: profileCode)
            } else if let code = tabs?.takeActivityTransaction(),
                      let txn = await model.transaction(code, profileCode: profileCode) {
                opened = txn
            }
        }
        .sheet(item: $opened) { txn in
            if canEdit {
                CategorySheet(transaction: txn, categories: model.meta?.assignableCategories ?? [],
                              profileCode: profileCode, target: model,
                              detail: model.detail(for: txn, profileCode: profileCode))
            } else {
                TransactionDetailSheet(model: model.detail(for: txn, profileCode: profileCode))
            }
        }
        .sheet(isPresented: $showFilters) {
            ActivityFilterSheet(initial: model.query, meta: model.meta, months: months) { draft in
                showFilters = false
                Task { await model.apply(draft, profileCode: profileCode) }
            }
        }
        .alert("Couldn't update", isPresented: Binding(get: { model.errorMessage != nil },
                                                      set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.state.errorMessage, model.state.value == nil {
            FailedCard(message: error, retry: reload).listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else if model.state.value == nil {
            LoadingCard().listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else if let empty = model.emptyMessage {
            EmptyCard(systemImage: "tray", message: empty).listRowBackground(Color.clear).listRowSeparator(.hidden)
        } else {
            ActivitySummaryRow(display: model.summaryDisplay)
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { txn in
                        row(txn)
                            .listRowBackground(Palette.bg)
                            .listRowSeparatorTint(Palette.border)
                            .onAppear { Task { await model.rowAppeared(txn) } }
                    }
                } header: {
                    // The day's net over every matching row, from the server (activity_day_totals).
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title).font(Typography.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        if let total = model.dayTotal(for: section.day) {
                            Text(total.label).font(Typography.caption).monospacedDigit()
                                .accessibilityLabel(total.accessibilityLabel)
                        }
                    }
                    .foregroundStyle(Palette.muted)
                }
            }
            PagingFooter(footer: model.footer, endMessage: model.endMessage) { await model.loadMore() }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func row(_ txn: LedgerTransaction) -> some View {
        if model.selection.isSelecting {
            let selected = model.selection.isSelected(txn.txnCode)
            Button { model.selection.toggle(txn.txnCode, loaded: model.loadedCodes) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Palette.accent : Palette.muted)
                        .accessibilityHidden(true)
                    TransactionRow(txn: txn)
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Removes it from the selection" : "Adds it to the selection")
        } else if canEdit {
            Button { opened = txn } label: { TransactionRow(txn: txn) }
                .swipeActions(edge: .trailing) {
                    Button("Categorise", systemImage: "tag") { opened = txn }.tint(Palette.accent)
                }
                .swipeActions(edge: .leading) {
                    Button(TransactionEditor.excludeActionTitle(excluded: txn.excludeFromSpend),
                           systemImage: txn.excludeFromSpend ? "plus.circle" : "minus.circle") {
                        Task { await model.toggleExcluded(txn, profileCode: profileCode) }
                    }
                    .tint(Palette.info)
                }
        } else {
            Button { opened = txn } label: { TransactionRow(txn: txn) }
        }
    }

    private func reload() { Task { await model.load(profileCode: profileCode) } }
}

struct TransactionRow: View {
    let txn: LedgerTransaction
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryDot(token: txn.categoryColor, size: 10).padding(.top, 6)
            AdaptiveRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(txn.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        .lineLimit(typeSize.prefersStackedRows ? 3 : 1)
                    meta
                    if let peer = txn.transferPeer { TransferPeerLabel(peer: peer) }
                }
            } trailing: {
                if typeSize.prefersStackedRows {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { amounts; chips }
                } else {
                    VStack(alignment: .trailing, spacing: 3) { amounts; chips }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var meta: some View {
        if typeSize.prefersStackedRows {
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.categoryCaption)
                BankCardLabel(bankCode: txn.bankCode, label: txn.cardSuffix, size: 16)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.muted)
        } else {
            HStack(spacing: 6) {
                Text(txn.categoryCaption)
                Text("·")
                BankCardLabel(bankCode: txn.bankCode, label: txn.cardSuffix, size: 16)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
        }
    }

    /// The evidence badge, after "Debit" for a purchase paid from a bank account (Wealth mode).
    private var chips: some View {
        HStack(spacing: 4) {
            if let tag = txn.paymentTag { Chip(label: tag, tone: .info) }
            Chip(label: txn.badge.label, tone: txn.badge.tone)
        }
    }

    @ViewBuilder private var amounts: some View {
        VStack(alignment: typeSize.prefersStackedRows ? .leading : .trailing, spacing: 2) {
            Text(txn.amountLabel).font(Typography.amount).moneyLine()
                .foregroundStyle(txn.isCredit ? Palette.positive : Palette.ink)
            if let original = txn.originalAmountLabel {
                Text(original).font(Typography.caption).moneyLine().foregroundStyle(Palette.muted)
            }
        }
    }
}

/// "Paid to [EIB logo] •9216" / "From [WIO logo] •9202" on a card-transfer row.
struct TransferPeerLabel: View {
    let peer: CardTransferPeer
    var size: CGFloat = 16
    var font: Font = Typography.caption

    var body: some View {
        HStack(spacing: 4) {
            Text(peer.prefix)
            BankCardLabel(bankCode: peer.bankCode, label: peer.cardSuffix, size: size, font: font)
        }
        .font(font)
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
    }
}
