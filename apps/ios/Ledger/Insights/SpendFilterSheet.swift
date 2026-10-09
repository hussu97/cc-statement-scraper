import LedgerKit
import SwiftUI

/// Which spend Monthly spend counts: a merchant search and multi-select
/// categories, banks and cards. Edits a copy; Done applies it, Clear empties
/// it, a swipe-down drops the edits.
struct SpendFilterSheet: View {
    let options: SpendFilterOptions?
    let apply: (SpendFilter) -> Void
    @State private var draft: SpendFilter
    @Environment(\.dismiss) private var dismiss

    init(initial: SpendFilter, options: SpendFilterOptions?, apply: @escaping (SpendFilter) -> Void) {
        self.options = options
        self.apply = apply
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Merchant or description", text: $draft.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                } header: {
                    Text("Search")
                }
                if let options {
                    OptionSection(title: "Categories", options: options.categories, selected: $draft.categoryCodes,
                                  showsDots: true)
                    OptionSection(title: "Banks", options: options.banks, selected: $draft.bankCodes)
                    OptionSection(title: "Cards", options: options.cards, selected: $draft.cardCodes)
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading categories, banks and cards…")
                                .font(Typography.rowMeta).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .navigationTitle("Filter spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { draft = SpendFilter() }.disabled(draft.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
    }
}

private struct OptionSection: View {
    let title: String
    let options: [SpendFilterOptions.Option]
    @Binding var selected: Set<String>
    var showsDots = false

    var body: some View {
        if !options.isEmpty {
            Section {
                ForEach(options) { option in
                    Button {
                        SpendFilter.toggle(option.code, in: &selected)
                    } label: {
                        OptionRow(option: option, isOn: selected.contains(option.code), showsDot: showsDots)
                    }
                    .accessibilityAddTraits(selected.contains(option.code) ? .isSelected : [])
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    if !selected.isEmpty {
                        Text("\(selected.count) selected").textCase(nil)
                    }
                }
            }
        }
    }
}

private struct OptionRow: View {
    let option: SpendFilterOptions.Option
    let isOn: Bool
    let showsDot: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsDot {
                Circle().fill(ChartPalette.color(for: option.colorToken)).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                if let detail = option.detail {
                    Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Palette.accent : Palette.borderStrong)
                .imageScale(.large)
        }
        .contentShape(Rectangle())
    }
}
