import LedgerKit
import SwiftUI

/// Dates, status, source, account, card and category filters for Activity, as
/// the web's filter bar. Edits a copy of the query: only Apply changes the
/// list; Cancel or a swipe-down drops it. `ActivityQuery` decides what each
/// choice means (presets, the card list, the source filter).
struct ActivityFilterSheet: View {
    let meta: FilterMeta?
    let months: MonthRange
    let apply: (ActivityQuery) -> Void
    @State private var query: ActivityQuery
    /// "Custom range" stays picked while its dates happen to equal a preset.
    @State private var customDates: Bool
    @Environment(\.dismiss) private var dismiss

    init(initial: ActivityQuery, meta: FilterMeta?, months: MonthRange, apply: @escaping (ActivityQuery) -> Void) {
        self.meta = meta
        self.months = months
        self.apply = apply
        _query = State(initialValue: initial)
        _customDates = State(initialValue: initial.dateChoice() == .custom)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Dates", selection: dateChoice) {
                        ForEach(ActivityDateChoice.all, id: \.self) { Text($0.label).tag($0) }
                    }
                    if customDates {
                        DatePicker("From", selection: day(\.from, fallback: today.startOfMonth),
                                   in: dateBounds, displayedComponents: .date)
                        DatePicker("To", selection: day(\.to, fallback: today), in: dateBounds, displayedComponents: .date)
                    }
                }
                .environment(\.timeZone, LedgerDates.timeZone)
                .environment(\.calendar, LedgerDates.calendar)
                Section {
                    Picker("Status", selection: $query.status) {
                        ForEach(ActivityQuery.StatusFilter.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Source", selection: $query.source) {
                        ForEach(ActivityQuery.SourceFilter.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Card") {
                    Picker("Account", selection: Binding(get: { query.accountCode }, set: { query.setAccount($0) })) {
                        Text("All accounts").tag(String?.none)
                        ForEach(meta?.accounts ?? []) { Text($0.title).tag(Optional($0.accountCode)) }
                    }
                    Picker("Card", selection: $query.cardCode) {
                        Text("All cards").tag(String?.none)
                        ForEach(meta?.cards(forAccount: query.accountCode) ?? []) {
                            Text($0.label).tag(Optional($0.cardCode))
                        }
                    }
                }
                Section("Category") {
                    Toggle("Uncategorised only", isOn: $query.uncategorizedOnly).tint(Palette.accent)
                    if !query.uncategorizedOnly {
                        Picker("Category", selection: $query.categoryCode) {
                            Text("All categories").tag(String?.none)
                            ForEach(meta?.assignableCategories ?? []) { Text($0.name).tag(Optional($0.categoryCode)) }
                        }
                    }
                }
                Section {
                    Button("Clear filters", role: .destructive) {
                        query.clearFilters()
                        customDates = false
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(query) } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var today: CalendarDay { LedgerDates.today() }

    /// From the ledger's first month to the end of this one.
    private var dateBounds: ClosedRange<Date> { months.earliest.startDate...today.endOfMonth.startDate }

    private var dateChoice: Binding<ActivityDateChoice> {
        Binding(get: { customDates ? .custom : query.dateChoice() },
                set: { choice in
                    customDates = choice == .custom
                    query.choose(choice)
                })
    }

    /// A custom-range end as a `Date` at Dubai midnight, written back as a calendar day.
    private func day(_ end: KeyPath<ActivityQuery, CalendarDay?>, fallback: CalendarDay) -> Binding<Date> {
        Binding(get: { (query[keyPath: end] ?? fallback).startDate },
                set: { date in
                    let picked = CalendarDay(date: date)
                    if end == \ActivityQuery.from {
                        query.setRange(from: picked, to: query.to)
                    } else {
                        query.setRange(from: query.from, to: picked)
                    }
                })
    }
}
