import LedgerKit
import SwiftUI

struct ActivityView: View {
    @Bindable var model: ActivityModel
    let profileCode: String
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
            await model.load(profileCode: profileCode)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: model.query.hasFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(model.query.hasFilters ? "Filters, active" : "Filters")
            }
        }
        .refreshable { await model.load(profileCode: profileCode) }
        .sheet(item: $editing) { txn in
            CategorySheet(transaction: txn, categories: model.meta?.assignableCategories ?? []) { code, all in
                await model.setCategory(txn, to: code, applyToMerchant: all, profileCode: profileCode)
            }
        }
        .sheet(isPresented: $showFilters) {
            ActivityFilterSheet(query: $model.query, meta: model.meta) {
                showFilters = false
                reload()
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
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { txn in
                        Button { editing = txn } label: { TransactionRow(txn: txn) }
                            .listRowBackground(Palette.bg)
                            .listRowSeparatorTint(Palette.border)
                    }
                } header: {
                    Text(section.title).font(Typography.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
            }
            if model.canLoadMore {
                Button {
                    Task { await model.loadMore(profileCode: profileCode) }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoadingMore { ProgressView() } else { Text("Load more") }
                        Spacer()
                    }
                }
                .listRowBackground(Palette.bg)
            }
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
                Text(txn.categoryName ?? "Uncategorized")
                Text(txn.cardLabel)
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.muted)
        } else {
            HStack(spacing: 6) {
                Text(txn.categoryName ?? "Uncategorized")
                Text("·")
                Text(txn.cardLabel)
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
