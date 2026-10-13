import LedgerKit
import SwiftUI

/// Insights' way into Trends (PAR-10).
struct TrendsLink: View {
    let profileCode: String

    var body: some View {
        NavigationLink {
            TrendsView(profileCode: profileCode)
        } label: {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trends").font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        Text("By day, week or month, over any range")
                            .font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.subtle)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens spending over time")
    }
}

/// Insights → Trends (BACKLOG PAR-10, the web's Insights "Trends" tab): spending over a range in
/// day, week or month buckets, as a total or split by category, bank, merchant, account or
/// card, with the filter Monthly spend has. `TrendsModel` (LedgerKit) decides; this draws.
struct TrendsView: View {
    let profileCode: String
    @Environment(SpendSplitModel.self) private var split
    @State private var model: TrendsModel?

    var body: some View {
        Group {
            if let model {
                TrendsScreen(model: model, profileCode: profileCode)
            } else {
                Page { LoadingCard().padding(.top, 8) }
            }
        }
        .ledgerNavigation("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model == nil { model = split.makeTrends() } }
    }
}

private struct TrendsScreen: View {
    @Bindable var model: TrendsModel
    let profileCode: String
    @State private var showsFilter = false

    var body: some View {
        Page {
            TrendsControls(model: model, showFilter: { showsFilter = true }).padding(.top, 8)
            TrendsResults(model: model, retry: { Task { await model.load(profileCode: profileCode, force: true) } })
        }
        .task(id: model.request(profileCode: profileCode)) { await model.load(profileCode: profileCode) }
        .refreshable { await model.load(profileCode: profileCode, force: true) }
        .sheet(isPresented: $showsFilter) {
            SpendFilterSheet(initial: model.filter, options: model.options) { model.filter = $0 }
                .task { await model.loadOptions(profileCode: profileCode) }
        }
    }
}

/// Range (preset or custom dates), grouping, bucket size and filter.
private struct TrendsControls: View {
    @Bindable var model: TrendsModel
    let showFilter: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spending over time").font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                    Text(model.range.label).font(Typography.caption).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                TrendsFilterButton(count: model.filter.activeCount, action: showFilter)
            }
            if let summary = model.filterSummary {
                TrendsFilterSummary(text: summary, clear: model.clearFilter)
            }
            row("Range") {
                Picker("Range", selection: $model.rangeChoice) {
                    ForEach(TrendsRangeChoice.all) { Text($0.label).tag($0) }
                }
            }
            if model.rangeChoice == .custom {
                Group {
                    DatePicker("From", selection: day(\.customFrom), in: ...model.customTo.startDate,
                               displayedComponents: .date)
                    DatePicker("To", selection: day(\.customTo),
                               in: model.customFrom.startDate...model.latestDay.startDate, displayedComponents: .date)
                }
                .font(Typography.rowMeta)
                .environment(\.timeZone, LedgerDates.timeZone)
                .environment(\.calendar, LedgerDates.calendar)
            }
            row("Group by") {
                Picker("Group by", selection: $model.group) {
                    ForEach(TrendsGroup.allCases) { Text($0.label).tag($0) }
                }
            }
            Picker("Bucket size", selection: $model.grain) {
                ForEach(model.grainOptions, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.group.monthlyOnly {
                Text("Bank splits are monthly.").font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private func row(_ title: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack {
            Text(title).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
            Spacer(minLength: 8)
            picker().pickerStyle(.menu).tint(Palette.accent)
        }
        .frame(minHeight: Metrics.tapMin)
    }

    /// A custom-date picker's binding: a Dubai calendar day as the picker's `Date`.
    private func day(_ path: ReferenceWritableKeyPath<TrendsModel, CalendarDay>) -> Binding<Date> {
        Binding(get: { model[keyPath: path].startDate },
                set: { model[keyPath: path] = CalendarDay(date: $0) })
    }
}

/// The filter button, with how many filters are on.
private struct TrendsFilterButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(count > 0 ? "Filter · \(count)" : "Filter")
            }
            .font(Typography.caption)
        }
        .buttonStyle(.borderless)
        .tint(Palette.accent)
        .accessibilityLabel(count > 0 ? "Filter, \(count) on" : "Filter")
    }
}

/// What the chart is filtered to, and a way back to all spend.
private struct TrendsFilterSummary: View {
    let text: String
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(Typography.caption).foregroundStyle(Palette.ink2).lineLimit(2)
            Spacer(minLength: 4)
            Button("Clear", action: clear).font(Typography.caption).buttonStyle(.borderless).tint(Palette.accent)
                .accessibilityLabel("Clear filters")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusSm))
        .accessibilityElement(children: .combine)
    }
}
