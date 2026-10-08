import LedgerKit
import SwiftUI

/// Change a transaction's category; optionally for every transaction from the
/// same merchant (`set_transaction_category(p_apply_to_merchant => true)`).
struct CategorySheet: View {
    let transaction: LedgerTransaction
    let categories: [FilterMeta.CategoryOption]
    let save: (String, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var applyToMerchant = false
    @State private var saving: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.title).font(Typography.rowTitle)
                        Text("\(transaction.amountLabel) · \(LedgerDates.dayLabel(transaction.txnDate))")
                            .font(Typography.rowMeta).monospacedDigit().foregroundStyle(Palette.muted)
                        if let source = transaction.categorySource {
                            Text("Category from \(source)").font(Typography.caption).foregroundStyle(Palette.subtle)
                        }
                    }
                    if transaction.merchantCode != nil {
                        Toggle("Apply to every \(transaction.title) transaction", isOn: $applyToMerchant)
                            .tint(Palette.accent)
                    }
                }
                Section("Category") {
                    if categories.isEmpty {
                        Text("Categories are loading…").foregroundStyle(Palette.muted)
                    }
                    ForEach(categories) { category in
                        Button {
                            Task {
                                saving = category.categoryCode
                                if await save(category.categoryCode, applyToMerchant) { dismiss() }
                                saving = nil
                            }
                        } label: {
                            HStack {
                                CategoryDot(token: category.colorToken, size: 10)
                                Text(category.name).foregroundStyle(Palette.ink)
                                Spacer()
                                if saving == category.categoryCode {
                                    ProgressView()
                                } else if category.categoryCode == transaction.categoryCode {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .disabled(saving != nil)
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Status, card and category filters for Activity.
struct ActivityFilterSheet: View {
    @Binding var query: ActivityQuery
    let meta: FilterMeta?
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: $query.status) {
                    ForEach(ActivityQuery.StatusFilter.allCases) { Text($0.label).tag($0) }
                }
                Picker("Card", selection: $query.accountCode) {
                    Text("All cards").tag(String?.none)
                    ForEach(meta?.accounts ?? []) { Text($0.title).tag(Optional($0.accountCode)) }
                }
                Toggle("Uncategorized only", isOn: $query.uncategorizedOnly).tint(Palette.accent)
                if !query.uncategorizedOnly {
                    Picker("Category", selection: $query.categoryCode) {
                        Text("All categories").tag(String?.none)
                        ForEach(meta?.assignableCategories ?? []) { Text($0.name).tag(Optional($0.categoryCode)) }
                    }
                }
                Section {
                    Button("Clear filters", role: .destructive) { query.clearFilters() }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Apply", action: apply) } }
        }
        .presentationDetents([.medium, .large])
    }
}
