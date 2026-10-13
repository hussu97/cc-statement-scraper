import LedgerKit
import SwiftUI

/// Activity's bulk bar (PAR-11, the web's `BulkBar`): the selection's count and net from the
/// server, "All" / "Select all N", Categorise and Exclude / Include. `ActivitySelection`
/// decides; this lays it out. Shown only in select mode, which only owners get.
struct ActivityBulkBar: View {
    let model: ActivityModel
    let profileCode: String
    @State private var categorising = false

    private var selection: ActivitySelection { model.selection }
    private var query: ActivityQuery { model.listedQuery }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = selection.notice {
                Label(notice, systemImage: "checkmark.circle").font(Typography.rowMeta).foregroundStyle(Palette.positive)
            }
            if let count = selection.countText(for: query) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(count).font(Typography.rowTitle).foregroundStyle(Palette.ink).monospacedDigit()
                    figures
                    Spacer(minLength: 4)
                    Button { selection.clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Palette.muted)
                        .frame(minWidth: Metrics.tapMin, minHeight: Metrics.tapMin)
                        .accessibilityLabel("Clear selection")
                }
                .accessibilityElement(children: .contain)
                actions
            } else if selection.notice == nil {
                Text("Tap transactions to select them.").font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .overlay(alignment: .top) { Divider().overlay(Palette.border) }
        .task(id: selection.notice) {
            guard selection.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            selection.notice = nil
        }
        .sheet(isPresented: $categorising) {
            BulkCategorySheet(categories: model.meta?.assignableCategories ?? [],
                              title: selection.countText(for: query) ?? "") { code in
                categorising = false
                Task { await model.applyBulk(.category(code), profileCode: profileCode) }
            }
        }
        .alert(selection.failure?.title ?? "", isPresented: Binding(get: { selection.failure != nil },
                                                                    set: { if !$0 { selection.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selection.failure?.message ?? "")
        }
    }

    /// The server's net, or why it isn't there.
    @ViewBuilder private var figures: some View {
        Text("·").foregroundStyle(Palette.muted).accessibilityHidden(true)
        if let summary = selection.summary.value {
            Text(summary.netText).font(Typography.rowMeta).foregroundStyle(Palette.ink2).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        } else if selection.summary.errorMessage != nil {
            Text("total unavailable").font(Typography.rowMeta).foregroundStyle(Palette.muted)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var actions: some View {
        let loaded = model.loadedCodes
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pickers(loaded); Spacer(minLength: 0); writes }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { pickers(loaded) }
                HStack(spacing: 8) { writes }
            }
        }
        .disabled(selection.busy != nil)
    }

    @ViewBuilder private func pickers(_ loaded: [String]) -> some View {
        if selection.offersSelectAllLoaded(loaded) {
            Button("All") { selection.selectAllLoaded(loaded) }.buttonStyle(.bordered).tint(Palette.ink2)
                .accessibilityLabel("Select all loaded")
        }
        if let total = selection.selectAllMatchingTotal(loaded: loaded, total: model.total) {
            Button("Select all \(MoneyFormat.grouped(Decimal(total), fractionDigits: 0))") { selection.selectAllMatching() }
                .buttonStyle(.bordered).tint(Palette.ink2)
        }
    }

    @ViewBuilder private var writes: some View {
        Button { categorising = true } label: {
            if isCategorising { ProgressView() } else { Label("Categorise", systemImage: "tag") }
        }
        .buttonStyle(.bordered).tint(Palette.accent)
        let patch = selection.excludePatch
        Button {
            Task { await model.applyBulk(patch, profileCode: profileCode) }
        } label: {
            if selection.busy == patch {
                ProgressView()
            } else if patch == .excludeFromSpend(false) {
                Label("Include", systemImage: "plus.circle")
            } else {
                Label("Exclude", systemImage: "minus.circle")
            }
        }
        .buttonStyle(.borderedProminent).tint(Palette.accent)
        .disabled(!selection.canExclude)
        .accessibilityLabel(patch == .excludeFromSpend(false) ? "Include in spending" : "Exclude from spending")
    }

    private var isCategorising: Bool {
        if case .category? = selection.busy { true } else { false }
    }
}

/// The bulk Categorise picker: the web's searchable list, without "Clear" (the web's bulk
/// picker only sets a category).
private struct BulkCategorySheet: View {
    let categories: [FilterMeta.CategoryOption]
    let title: String
    let choose: (String) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if categories.isEmpty {
                    Text("Categories are loading…").foregroundStyle(Palette.muted)
                }
                let visible = TransactionEditor.filter(categories, search: search)
                ForEach(visible) { category in
                    Button { choose(category.categoryCode) } label: {
                        HStack {
                            CategoryDot(token: category.colorToken, size: 10)
                            Text(category.name).foregroundStyle(Palette.ink)
                        }
                    }
                }
                if !categories.isEmpty && visible.isEmpty {
                    Text("No category matches “\(search.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(Palette.muted)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a category")
            .navigationTitle("Categorise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Categorise").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text(title).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
