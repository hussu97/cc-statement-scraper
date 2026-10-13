import LedgerKit
import SwiftUI

struct ActivityView: View {
    @Bindable var model: ActivityModel
    let months: MonthRange
    let profileCode: String
    /// Owners recategorise; viewers and view-only ledgers just read.
    let canEdit: Bool
    /// Hands over the filters of a deep link (`ledger://uncategorised`).
    var tabs: TabRouter?
    @State private var editing: LedgerTransaction?
    @State private var showFilters = false

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .ledgerNavigation("Activity")
        .searchable(text: $model.query.search, prompt: "Merchant or description")
        .onSubmit(of: .search) { reload() }
        .task(id: model.query.search) {
            // Debounce typing; the model drops superseded responses.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.loadIfNeeded(profileCode: profileCode)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: model.query.hasFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(model.query.hasFilters ? "Filters, \(model.query.filterCount) active" : "Filters")
            }
        }
        .refreshable { await model.load(profileCode: profileCode) }
        // ledger://uncategorised (the Control): this month's uncategorised rows. Keyed on the
        // request count, not the preset: taking the preset must not cancel this task.
        .task(id: tabs?.activityPresetRequest) {
            guard let preset = tabs?.takeActivityPreset() else { return }
            await model.apply(preset, profileCode: profileCode)
        }
        .sheet(item: $editing) { txn in
            CategorySheet(transaction: txn, categories: model.meta?.assignableCategories ?? [],
                          profileCode: profileCode, target: model)
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
                    Text(section.title).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
            }
            PagingFooter(footer: model.footer, endMessage: model.endMessage) { await model.loadMore() }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func row(_ txn: LedgerTransaction) -> some View {
        if canEdit {
            Button { editing = txn } label: { TransactionRow(txn: txn) }
                .swipeActions(edge: .trailing) {
                    Button("Categorise", systemImage: "tag") { editing = txn }.tint(Palette.accent)
                }
                .swipeActions(edge: .leading) {
                    Button(TransactionEditor.excludeActionTitle(excluded: txn.excludeFromSpend),
                           systemImage: txn.excludeFromSpend ? "plus.circle" : "minus.circle") {
                        Task { await model.toggleExcluded(txn, profileCode: profileCode) }
                    }
                    .tint(Palette.info)
                }
        } else {
            TransactionRow(txn: txn)
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) { amounts; Chip(label: txn.badge.label, tone: txn.badge.tone) }
                } else {
                    VStack(alignment: .trailing, spacing: 3) { amounts; Chip(label: txn.badge.label, tone: txn.badge.tone) }
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
